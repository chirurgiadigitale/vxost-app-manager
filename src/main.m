//
//  main.m
//  VXOST, punto di ingresso.
//
//  L'app sta in due posti contemporaneamente: l'icona nel Dock apre la
//  finestra con tutte le funzioni, quella nella barra di stato dà accesso
//  rapido agli stessi comandi senza lasciare il lavoro in corso.
//

#import <Cocoa/Cocoa.h>
#import "XPStatusController.h"
#import "XPServiceMonitor.h"
#import "XPMainWindowController.h"
#import "XPLogWindowController.h"
#import "XPActions.h"
#import "XPTheme.h"

@interface XPAppDelegate : NSObject <NSApplicationDelegate>
@property (nonatomic, strong) XPStatusController *statusController;
@end

@implementation XPAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    // Prima di costruire qualsiasi vista: il tema decide i colori.
    [XPTheme applyStoredPreference];
    [self buildMainMenu];

    self.statusController = [[XPStatusController alloc] init];
    [self.statusController install];
    [[XPServiceMonitor shared] start];

    // Chi lancia dall'icona del Dock si aspetta una finestra.
    [[XPMainWindowController shared] present];
}

/// Clic sull'icona nel Dock ad app già avviata: la finestra torna in primo
/// piano invece di non fare nulla.
- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)visible {
    [[XPMainWindowController shared] present];
    return YES;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    // Chiudere la finestra non chiude l'app: resta nella barra di stato a
    // sorvegliare i servizi.
    return NO;
}

// Mentre l'utente lavora su altro non ha senso interrogare processi e porte
// due volte al secondo: la cadenza rapida serve solo quando l'app è davanti.

- (void)applicationDidResignActive:(NSNotification *)notification {
    [[XPServiceMonitor shared] setFastPolling:NO];
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    if ([XPMainWindowController shared].window.isVisible) {
        [[XPServiceMonitor shared] setFastPolling:YES];
        [[XPServiceMonitor shared] refreshNow];
    }
}

#pragma mark - Menu dell'applicazione

/// Costruisce il menu di sistema. Senza, l'app non avrebbe nemmeno ⌘Q né le
/// scorciatoie di modifica nei campi di testo.
- (void)buildMainMenu {
    NSMenu *mainMenu = [[NSMenu alloc] init];

    // --- Menu applicazione ---
    NSMenuItem *appItem = [[NSMenuItem alloc] init];
    [mainMenu addItem:appItem];
    NSMenu *appMenu = [[NSMenu alloc] init];

    [appMenu addItemWithTitle:NSLocalizedString(@"menu.about", nil)
                       action:@selector(orderFrontStandardAboutPanel:)
                keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *dashboard = [appMenu addItemWithTitle:NSLocalizedString(@"menu.openDashboard", nil)
                                               action:@selector(openDashboard:)
                                        keyEquivalent:@"d"];
    dashboard.target = self;

    NSMenuItem *phpmyadmin = [appMenu addItemWithTitle:NSLocalizedString(@"menu.openPhpMyAdmin", nil)
                                                action:@selector(openPhpMyAdmin:)
                                         keyEquivalent:@"m"];
    phpmyadmin.target = self;

    NSMenuItem *logs = [appMenu addItemWithTitle:NSLocalizedString(@"menu.viewLogs", nil)
                                          action:@selector(openLogs:)
                                   keyEquivalent:@"l"];
    logs.target = self;

    // Sottomenu del tema, con il segno di spunta sulla scelta corrente.
    NSMenuItem *themeItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"menu.theme", nil) action:nil keyEquivalent:@""];
    NSMenu *themeMenu = [[NSMenu alloc] initWithTitle:NSLocalizedString(@"menu.theme", nil)];
    for (XPThemePreference pref = XPThemePreferenceAuto; pref <= XPThemePreferenceLight; pref++) {
        NSMenuItem *item = [themeMenu addItemWithTitle:[XPTheme nameForPreference:pref]
                                                 action:@selector(changeTheme:)
                                          keyEquivalent:@""];
        item.target = self;
        item.tag = pref;
        item.state = ([XPTheme preference] == pref) ? NSControlStateValueOn : NSControlStateValueOff;
    }
    themeItem.submenu = themeMenu;
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItem:themeItem];

    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:NSLocalizedString(@"menu.hide", nil) action:@selector(hide:) keyEquivalent:@"h"];
    [appMenu addItemWithTitle:NSLocalizedString(@"menu.quit", nil) action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = appMenu;

    // --- Menu Servizi ---
    NSMenuItem *servicesItem = [[NSMenuItem alloc] init];
    [mainMenu addItem:servicesItem];
    NSMenu *servicesMenu = [[NSMenu alloc] initWithTitle:NSLocalizedString(@"menu.services", nil)];

    NSMenuItem *startAll = [servicesMenu addItemWithTitle:NSLocalizedString(@"btn.startAll", nil)
                                                   action:@selector(startAll:)
                                            keyEquivalent:@"r"];
    startAll.target = self;

    NSMenuItem *stopAll = [servicesMenu addItemWithTitle:NSLocalizedString(@"btn.stopAll", nil)
                                                  action:@selector(stopAll:)
                                           keyEquivalent:@"."];
    stopAll.target = self;

    NSMenuItem *restart = [servicesMenu addItemWithTitle:NSLocalizedString(@"btn.restart", nil)
                                                  action:@selector(restartAll:)
                                           keyEquivalent:@"R"];
    restart.target = self;
    servicesItem.submenu = servicesMenu;

    // --- Menu Modifica: senza, copia e incolla non funzionano nel log ---
    NSMenuItem *editItem = [[NSMenuItem alloc] init];
    [mainMenu addItem:editItem];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:NSLocalizedString(@"menu.edit", nil)];
    [editMenu addItemWithTitle:NSLocalizedString(@"menu.copy", nil) action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:NSLocalizedString(@"menu.selectAll", nil) action:@selector(selectAll:) keyEquivalent:@"a"];
    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItemWithTitle:NSLocalizedString(@"menu.find", nil) action:@selector(performFindPanelAction:) keyEquivalent:@"f"];
    editItem.submenu = editMenu;

    // --- Menu Finestra ---
    NSMenuItem *windowItem = [[NSMenuItem alloc] init];
    [mainMenu addItem:windowItem];
    NSMenu *windowMenu = [[NSMenu alloc] initWithTitle:NSLocalizedString(@"menu.window", nil)];

    NSMenuItem *mainWindow = [windowMenu addItemWithTitle:NSLocalizedString(@"menu.openWindow", nil)
                                                   action:@selector(openMainWindow:)
                                            keyEquivalent:@"0"];
    mainWindow.target = self;

    [windowMenu addItemWithTitle:NSLocalizedString(@"menu.minimize", nil) action:@selector(performMiniaturize:) keyEquivalent:@"m"];
    [windowMenu addItemWithTitle:NSLocalizedString(@"menu.close", nil) action:@selector(performClose:) keyEquivalent:@"w"];
    windowItem.submenu = windowMenu;
    NSApp.windowsMenu = windowMenu;

    NSApp.mainMenu = mainMenu;
}

#pragma mark - Voci di menu

- (void)changeTheme:(NSMenuItem *)sender {
    [XPTheme setPreference:(XPThemePreference)sender.tag];
    // Riallinea i segni di spunta del sottomenu.
    for (NSMenuItem *item in sender.menu.itemArray) {
        item.state = (item.tag == sender.tag) ? NSControlStateValueOn : NSControlStateValueOff;
    }
}

- (void)openDashboard:(id)sender    { [[XPActions shared] openDashboard]; }
- (void)openPhpMyAdmin:(id)sender   { [[XPActions shared] openPhpMyAdmin]; }
- (void)openLogs:(id)sender         { [[XPLogWindowController shared] showWindowAndReload]; }
- (void)openMainWindow:(id)sender   { [[XPMainWindowController shared] present]; }
- (void)startAll:(id)sender         { [[XPActions shared] startAll]; }
- (void)stopAll:(id)sender          { [[XPActions shared] stopAll]; }
- (void)restartAll:(id)sender       { [[XPActions shared] restartAll]; }

@end


int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        XPAppDelegate *delegate = [[XPAppDelegate alloc] init];
        app.delegate = delegate;

        // Regular: icona nel Dock e menu applicazione, oltre alla presenza
        // nella barra di stato.
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        [app run];
    }
    return 0;
}
