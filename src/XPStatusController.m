//
//  XPStatusController.m
//

#import "XPStatusController.h"
#import "XPPanelView.h"
#import "XPTheme.h"
#import "XPPaths.h"
#import "XPService.h"
#import "XPServiceMonitor.h"
#import "XPActions.h"
#import "XPUpdateCheck.h"
#import "XPSetupWizard.h"
#import "XPLogWindowController.h"
#import "XPMainWindowController.h"

@interface XPStatusController () <XPPanelViewDelegate, NSPopoverDelegate>
@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) NSPopover *popover;
@property (nonatomic, strong) XPPanelView *panel;
@end


@implementation XPStatusController

#pragma mark - Installazione

- (void)install {
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.target = self;
    self.statusItem.button.action = @selector(togglePopover:);
    self.statusItem.button.toolTip = @"VXOST";
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
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(actionDidReport:)
                                                 name:XPActionMessageNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateCheckDidFinish:)
                                                 name:XPUpdateCheckDidFinishNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(themeDidChange:)
                                                 name:XPThemeDidChangeNotification
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
    // Il polling rapido resta se la finestra principale è aperta: anche lei
    // mostra lo stato in tempo reale.
    if (![XPMainWindowController shared].window.isVisible) {
        [[XPServiceMonitor shared] setFastPolling:NO];
    }
}

- (void)showContextMenu {
    NSMenu *menu = [[NSMenu alloc] init];
    [menu addItemWithTitle:NSLocalizedString(@"menu.openWindow", nil) action:@selector(menuOpenWindow:) keyEquivalent:@""].target = self;
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:NSLocalizedString(@"menu.openDashboard", nil) action:@selector(menuOpenDashboard:) keyEquivalent:@""].target = self;
    [menu addItemWithTitle:NSLocalizedString(@"menu.viewLogs", nil) action:@selector(menuOpenLogs:) keyEquivalent:@""].target = self;
    [menu addItemWithTitle:NSLocalizedString(@"menu.setup", nil) action:@selector(menuSetup:) keyEquivalent:@""].target = self;
    [menu addItem:[NSMenuItem separatorItem]];

    // Aggiornamenti. La voce dice cosa si sa adesso, e non "cerca
    // aggiornamenti": la ricerca la fa l'app da sé, e chiederlo a mano resta
    // possibile ma non è più il modo normale di saperlo.
    XPUpdateCheck *updates = [XPUpdateCheck shared];
    if (updates.availableVersion) {
        NSMenuItem *item = [menu addItemWithTitle:
            [NSString stringWithFormat:NSLocalizedString(@"update.available", nil),
             updates.availableVersion]
                                           action:@selector(menuDownloadUpdate:)
                                    keyEquivalent:@""];
        item.target = self;
    } else {
        NSMenuItem *item = [menu addItemWithTitle:NSLocalizedString(@"update.check", nil)
                                           action:@selector(menuCheckForUpdates:)
                                    keyEquivalent:@""];
        item.target = self;
    }
    NSMenuItem *toggle = [menu addItemWithTitle:NSLocalizedString(@"update.automatic", nil)
                                         action:@selector(menuToggleAutomatic:)
                                  keyEquivalent:@""];
    toggle.target = self;
    toggle.state = updates.automatic ? NSControlStateValueOn : NSControlStateValueOff;

    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:NSLocalizedString(@"btn.quit", nil) action:@selector(menuQuit:) keyEquivalent:@"q"].target = self;

    // Assegnare il menu allo status item lo fa comparire al click successivo,
    // quindi si mostra una volta sola e si stacca subito.
    self.statusItem.menu = menu;
    [self.statusItem.button performClick:nil];
    self.statusItem.menu = nil;
}

- (void)menuOpenWindow:(id)sender    { [[XPMainWindowController shared] present]; }
- (void)menuOpenDashboard:(id)sender { [[XPActions shared] openDashboard]; }
- (void)menuOpenLogs:(id)sender      { [[XPLogWindowController shared] showWindowAndReload]; }
- (void)menuSetup:(id)sender         { [XPSetupWizard present]; }
- (void)menuQuit:(id)sender          { [NSApp terminate:nil]; }

- (void)menuDownloadUpdate:(id)sender {
    NSString *url = [XPUpdateCheck shared].downloadURL;
    if (url.length > 0) [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:url]];
}

- (void)menuCheckForUpdates:(id)sender {
    [[XPActions shared] checkForUpdates];
}

- (void)menuToggleAutomatic:(id)sender {
    XPUpdateCheck *updates = [XPUpdateCheck shared];
    updates.automatic = !updates.automatic;
    [[XPActions shared] postMessage:(updates.automatic
                                     ? NSLocalizedString(@"update.automatic.on", nil)
                                     : NSLocalizedString(@"update.automatic.off", nil))
                            isError:NO];
}

#pragma mark - Aggiornamenti di stato

- (void)servicesDidChange:(NSNotification *)note {
    [self updateStatusIcon];
    [self.panel refresh];
}

- (void)actionDidReport:(NSNotification *)note {
    [self.panel showMessage:note.userInfo[@"message"]
                    isError:[note.userInfo[@"isError"] boolValue]];
}

/// L'esito del controllo si dice solo quando c'è qualcosa da dire.
///
/// ⚠️ Un "sei aggiornato" che compare da solo una volta al giorno è un avviso
/// per una non-notizia. Chi lo ha chiesto dal menu invece una risposta la
/// aspetta, e quella arriva perché il controllo manuale scrive comunque.
- (void)updateCheckDidFinish:(NSNotification *)note {
    // Il controllo chiesto da una persona lo racconta XPActions con un
    // avviso: scriverlo anche qui vorrebbe dire dire la stessa cosa due
    // volte, nell'avviso e nella riga in fondo alla finestra.
    if ([note.userInfo[@"manual"] boolValue]) return;

    if ([note.userInfo[@"available"] boolValue]) {
        [[XPActions shared] postMessage:
            [NSString stringWithFormat:NSLocalizedString(@"update.available", nil),
             note.userInfo[@"version"]] isError:NO];
    } else if ([note.userInfo[@"manual"] boolValue]) {
        [[XPActions shared] postMessage:NSLocalizedString(@"update.current", nil)
                                isError:NO];
    }
}

/// Al cambio di tema il pannello viene ricostruito: i colori delle etichette
/// sono assegnati alla creazione e non seguirebbero da soli.
- (void)themeDidChange:(NSNotification *)note {
    BOOL wasShown = self.popover.isShown;
    if (wasShown) [self.popover performClose:nil];

    self.panel = [[XPPanelView alloc] initWithServices:[XPServiceMonitor shared].services];
    self.panel.delegate = self;

    NSViewController *contentController = [[NSViewController alloc] init];
    contentController.view = self.panel;
    self.popover.contentViewController = contentController;
    self.popover.contentSize = NSMakeSize(NSWidth(self.panel.frame), self.panel.requiredHeight);

    [self.panel refresh];
    [self updateStatusIcon];

    if (wasShown) {
        [self.popover showRelativeToRect:self.statusItem.button.bounds
                                  ofView:self.statusItem.button
                           preferredEdge:NSRectEdgeMinY];
    }
}

#pragma mark - XPPanelViewDelegate
//
// Il pannello non conosce le operazioni: le inoltra tutte a XPActions, che è
// la stessa logica usata dalla finestra principale.

- (void)panelDidToggleService:(XPService *)service { [[XPActions shared] toggleService:service]; }
- (void)panelDidRequestReload:(XPService *)service { [[XPActions shared] reloadService:service]; }
- (void)panelDidRequestStartAll { [[XPActions shared] startAll]; }
- (void)panelDidRequestStopAll  { [[XPActions shared] stopAll]; }
- (void)panelDidRequestRestart  { [[XPActions shared] restartAll]; }

- (void)panelDidRequestOpenDashboard {
    [[XPActions shared] openDashboard];
    [self.popover performClose:nil];
}

- (void)panelDidRequestOpenPhpMyAdmin {
    [[XPActions shared] openPhpMyAdmin];
    [self.popover performClose:nil];
}

- (void)panelDidRequestOpenHtdocs {
    [[XPActions shared] openHtdocs];
    [self.popover performClose:nil];
}

- (void)panelDidRequestOpenLogs {
    [[XPLogWindowController shared] showWindowAndReload];
    [self.popover performClose:nil];
}

- (void)panelDidRequestOpenMainWindow {
    [[XPMainWindowController shared] present];
    [self.popover performClose:nil];
}

- (void)panelDidRequestOpenFile:(NSString *)path {
    [[XPActions shared] revealFile:path];
    [self.popover performClose:nil];
}

- (void)panelDidRequestVxostAction:(NSString *)action confirmMessage:(NSString *)message {
    [self.popover performClose:nil];

    if ([action isEqualToString:@"security"])      [[XPActions shared] runSecurityCheck];
    else if ([action isEqualToString:@"backup"])   [[XPActions shared] runBackup];
    else if ([action isEqualToString:@"enablessl"])[[XPActions shared] enableSSL];
    else                                           [[XPActions shared] disableSSL];
}

- (void)panelDidRequestQuit {
    [NSApp terminate:nil];
}

#pragma mark - Avvisi

- (void)showInstallationMissingAlert {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = NSLocalizedString(@"alert.missing.title", nil);
    alert.informativeText = [NSString stringWithFormat:
        NSLocalizedString(@"alert.missing.body", nil), [XPPaths controlScript]];
    alert.alertStyle = NSAlertStyleWarning;
    [alert addButtonWithTitle:NSLocalizedString(@"btn.understood", nil)];
    [alert runModal];
}

@end
