//
//  XPStatusController.m
//

#import "XPStatusController.h"
#import "XPPanelView.h"
#import "XPTheme.h"
#import "XPPaths.h"
#import "XPService.h"
#import "XPServiceMonitor.h"
#import "XPTaskRunner.h"
#import "XPLogWindowController.h"

@interface XPStatusController () <XPPanelViewDelegate, NSPopoverDelegate>
@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) NSPopover *popover;
@property (nonatomic, strong) XPPanelView *panel;
@property (nonatomic, strong) id eventMonitor;
@end


@implementation XPStatusController

#pragma mark - Installazione

- (void)install {
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.target = self;
    self.statusItem.button.action = @selector(togglePopover:);
    self.statusItem.button.toolTip = @"XAMPP Manager";
    [self.statusItem.button sendActionOn:(NSEventMaskLeftMouseUp | NSEventMaskRightMouseUp)];

    self.panel = [[XPPanelView alloc] initWithServices:[XPServiceMonitor shared].services];
    self.panel.delegate = self;

    NSViewController *contentController = [[NSViewController alloc] init];
    contentController.view = self.panel;

    self.popover = [[NSPopover alloc] init];
    self.popover.contentViewController = contentController;
    self.popover.behavior = NSPopoverBehaviorTransient;
    self.popover.animates = YES;
    self.popover.delegate = self;
    self.popover.contentSize = NSMakeSize(NSWidth(self.panel.frame), self.panel.requiredHeight);

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(servicesDidChange:)
                                                 name:XPServicesDidChangeNotification
                                               object:nil];

    [self updateStatusIcon];

    if (![XPPaths installationIsValid]) {
        [self showInstallationMissingAlert];
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Icona della barra di stato

/// Tre barrette, una per servizio: accese nel colore del servizio quando è
/// attivo, spente quando è fermo. Lo stato dell'intero stack si legge senza
/// aprire il pannello.
- (void)updateStatusIcon {
    NSArray<XPService *> *services = [XPServiceMonitor shared].services;

    NSSize size = NSMakeSize(22, 18);
    NSImage *image = [NSImage imageWithSize:size flipped:NO drawingHandler:^BOOL(NSRect rect) {
        CGFloat barWidth = 3.0;
        CGFloat gap = 3.0;
        CGFloat totalWidth = barWidth * services.count + gap * (services.count - 1);
        CGFloat x = (size.width - totalWidth) / 2.0;
        CGFloat heights[3] = {8.0, 12.0, 10.0};

        for (NSUInteger i = 0; i < services.count; i++) {
            XPService *service = services[i];
            CGFloat h = heights[MIN(i, 2)];
            NSRect bar = NSMakeRect(x, (size.height - h) / 2.0, barWidth, h);
            NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:bar xRadius:1.5 yRadius:1.5];

            if (service.state == XPServiceStateRunning) {
                [service.tint setFill];
                [path fill];
            } else {
                // Contorno soltanto: distingue "fermo" da "attivo" anche in
                // assenza di percezione del colore.
                [[NSColor tertiaryLabelColor] setStroke];
                path.lineWidth = 1.0;
                [path stroke];
            }
            x += barWidth + gap;
        }
        return YES;
    }];

    image.template = NO;   // i colori dei servizi devono restare
    self.statusItem.button.image = image;
}

#pragma mark - Popover

- (void)togglePopover:(id)sender {
    NSEvent *event = [NSApp currentEvent];

    // Click destro: menu rapido, senza aprire il pannello.
    if (event.type == NSEventTypeRightMouseUp) {
        [self showContextMenu];
        return;
    }

    if (self.popover.isShown) {
        [self.popover performClose:nil];
    } else {
        [self.panel refresh];
        [self.popover showRelativeToRect:self.statusItem.button.bounds
                                  ofView:self.statusItem.button
                           preferredEdge:NSRectEdgeMinY];
        [NSApp activateIgnoringOtherApps:YES];
        [[XPServiceMonitor shared] setFastPolling:YES];
        [[XPServiceMonitor shared] refreshNow];
    }
}

- (void)popoverDidClose:(NSNotification *)notification {
    [[XPServiceMonitor shared] setFastPolling:NO];
}

- (void)showContextMenu {
    NSMenu *menu = [[NSMenu alloc] init];
    [menu addItemWithTitle:@"Apri Dashboard" action:@selector(menuOpenDashboard:) keyEquivalent:@""].target = self;
    [menu addItemWithTitle:@"Log…" action:@selector(menuOpenLogs:) keyEquivalent:@""].target = self;
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:@"Esci" action:@selector(menuQuit:) keyEquivalent:@"q"].target = self;

    // Assegnare il menu allo status item lo fa comparire al click successivo,
    // quindi si mostra una volta sola e si stacca subito.
    self.statusItem.menu = menu;
    [self.statusItem.button performClick:nil];
    self.statusItem.menu = nil;
}

- (void)menuOpenDashboard:(id)sender { [self panelDidRequestOpenDashboard]; }
- (void)menuOpenLogs:(id)sender      { [self panelDidRequestOpenLogs]; }
- (void)menuQuit:(id)sender          { [self panelDidRequestQuit]; }

#pragma mark - Aggiornamenti di stato

- (void)servicesDidChange:(NSNotification *)note {
    [self updateStatusIcon];
    [self.panel refresh];
}

#pragma mark - Esecuzione azioni

/// Esegue un'azione dello script xampp marcando i servizi come "in transizione".
- (void)performAction:(NSString *)action
            onServices:(NSArray<XPService *> *)services
           description:(NSString *)description {

    for (XPService *service in services) service.state = XPServiceStateBusy;
    [self.panel refresh];
    [self updateStatusIcon];
    [self.panel showMessage:[NSString stringWithFormat:@"%@…", description] isError:NO];

    [XPTaskRunner runPrivilegedXamppAction:action completion:^(XPTaskResult *result) {
        // Lo stato torna a essere dedotto dai processi reali.
        for (XPService *service in services) service.state = XPServiceStateStopped;

        if (result.cancelled) {
            [self.panel showMessage:@"Operazione annullata" isError:NO];
        } else if (!result.succeeded) {
            [self.panel showMessage:[self firstMeaningfulLine:result.output] isError:YES];
        } else {
            [self.panel showMessage:[NSString stringWithFormat:@"%@: fatto", description] isError:NO];
        }

        // I demoni impiegano un istante a comparire o sparire dalla tabella
        // dei processi: si rilegge subito e poi ancora dopo un secondo.
        [[XPServiceMonitor shared] refreshNow];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [[XPServiceMonitor shared] refreshNow];
        });
    }];
}

/// Estrae dall'output la prima riga utile da mostrare all'utente.
- (NSString *)firstMeaningfulLine:(NSString *)output {
    for (NSString *line in [output componentsSeparatedByString:@"\n"]) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:
                             [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length > 0) return trimmed;
    }
    return @"Comando fallito";
}

#pragma mark - XPPanelViewDelegate

- (void)panelDidToggleService:(XPService *)service {
    BOOL running = (service.state == XPServiceStateRunning);
    NSString *action = running ? service.stopAction : service.startAction;
    NSString *description = [NSString stringWithFormat:@"%@ di %@",
                             running ? @"Arresto" : @"Avvio", service.name];
    [self performAction:action onServices:@[service] description:description];
}

- (void)panelDidRequestReload:(XPService *)service {
    [self performAction:service.reloadAction
             onServices:@[service]
            description:[NSString stringWithFormat:@"Ricarica di %@", service.name]];
}

- (void)panelDidRequestStartAll {
    [self performAction:@"start"
             onServices:[XPServiceMonitor shared].services
            description:@"Avvio dei servizi"];
}

- (void)panelDidRequestStopAll {
    [self performAction:@"stop"
             onServices:[XPServiceMonitor shared].services
            description:@"Arresto dei servizi"];
}

- (void)panelDidRequestRestart {
    [self performAction:@"restart"
             onServices:[XPServiceMonitor shared].services
            description:@"Riavvio dei servizi"];
}

- (void)panelDidRequestOpenDashboard {
    [self openURLString:@"http://localhost/dashboard/"];
}

- (void)panelDidRequestOpenPhpMyAdmin {
    [self openURLString:@"http://localhost/phpmyadmin/"];
}

- (void)panelDidRequestOpenHtdocs {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:[XPPaths htdocs]]];
    [self.popover performClose:nil];
}

- (void)panelDidRequestOpenLogs {
    [[XPLogWindowController shared] showWindowAndReload];
    [self.popover performClose:nil];
}

- (void)panelDidRequestOpenFile:(NSString *)path {
    if (!path) return;
    BOOL isDirectory = NO;
    [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDirectory];

    if (isDirectory) {
        [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:path]];
    } else {
        // Mostra il file selezionato nel Finder: aprirlo direttamente
        // rischierebbe di lanciare un editor che poi non può salvare, visto
        // che i file di configurazione appartengono a root.
        [[NSWorkspace sharedWorkspace] selectFile:path inFileViewerRootedAtPath:@""];
    }
    [self.popover performClose:nil];
}

- (void)panelDidRequestXamppAction:(NSString *)action confirmMessage:(NSString *)message {
    // security e backup pongono domande interattive: vanno eseguiti in un
    // terminale, altrimenti resterebbero bloccati in attesa di input.
    if ([action isEqualToString:@"security"] || [action isEqualToString:@"backup"]) {
        [self runInTerminal:action];
        return;
    }

    if (message) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Confermi l'operazione?";
        alert.informativeText = message;
        [alert addButtonWithTitle:@"Procedi"];
        [alert addButtonWithTitle:@"Annulla"];
        alert.alertStyle = NSAlertStyleWarning;

        [self.popover performClose:nil];
        [NSApp activateIgnoringOtherApps:YES];
        if ([alert runModal] != NSAlertFirstButtonReturn) return;
    }

    NSString *description = [action isEqualToString:@"enablessl"] ? @"Abilitazione SSL" : @"Disabilitazione SSL";
    [self performAction:action onServices:[XPServiceMonitor shared].services description:description];
}

/// Apre il Terminale sul comando indicato, per le operazioni interattive.
- (void)runInTerminal:(NSString *)action {
    NSString *command = [NSString stringWithFormat:@"sudo '%@' %@", XPControlScript, action];
    NSString *script = [NSString stringWithFormat:
        @"tell application \"Terminal\"\n"
        @"  activate\n"
        @"  do script \"%@\"\n"
        @"end tell", command];

    [self.popover performClose:nil];

    NSAppleScript *appleScript = [[NSAppleScript alloc] initWithSource:script];
    NSDictionary *error = nil;
    [appleScript executeAndReturnError:&error];
    if (error) {
        [self.panel showMessage:@"Impossibile aprire il Terminale" isError:YES];
    }
}

- (void)panelDidRequestQuit {
    [NSApp terminate:nil];
}

#pragma mark - Utilità

- (void)openURLString:(NSString *)urlString {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:urlString]];
    [self.popover performClose:nil];
}

- (void)showInstallationMissingAlert {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Installazione XAMPP non trovata";
    alert.informativeText = [NSString stringWithFormat:
        @"Lo script di controllo non è presente o non è eseguibile:\n%@\n\n"
         "L'app resta aperta ma non potrà avviare o fermare i servizi.", XPControlScript];
    alert.alertStyle = NSAlertStyleWarning;
    [alert addButtonWithTitle:@"Ho capito"];
    [alert runModal];
}

@end
