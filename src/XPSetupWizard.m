//
//  XPSetupWizard.m
//

#import "XPSetupWizard.h"
#import "XPTheme.h"
#import "XPButton.h"
#import "XPPaths.h"
#import "XPNetwork.h"
#import "XPExposure.h"
#import "XPDatabase.h"
#import "XPActions.h"
#import "XPUpdateCheck.h"

static const CGFloat XPSetupWidth   = 520;
static const CGFloat XPSetupHeight  = 430;
static const CGFloat XPSetupPadding = 26;

static NSString *const XPSetupDoneKey = @"SetupCompleted";

/// Le quindici lingue, nel nome che usa chi le parla.
///
/// ⚠️ I codici non sono quelli delle cartelle della dashboard: macOS vuole
/// `ja` e non `jp`, `zh-Hans` e non `zh_cn`. Sbagliarli non dà un errore, dà
/// un'app che resta in inglese.
static NSArray<NSArray<NSString *> *> *XPLanguages(void) {
    return @[
        @[@"en",      @"English"],
        @[@"it",      @"Italiano"],
        @[@"de",      @"Deutsch"],
        @[@"es",      @"Español"],
        @[@"fr",      @"Français"],
        @[@"pt-BR",   @"Português (Brasil)"],
        @[@"ro",      @"Română"],
        @[@"hu",      @"Magyar"],
        @[@"pl",      @"Polski"],
        @[@"ru",      @"Русский"],
        @[@"tr",      @"Türkçe"],
        @[@"ja",      @"日本語"],
        @[@"zh-Hans", @"简体中文"],
        @[@"zh-Hant", @"繁體中文"],
        @[@"ur",      @"اردو"],
    ];
}

@interface XPSetupWizard () <NSWindowDelegate>

@property (nonatomic, assign) NSInteger step;
@property (nonatomic, strong) NSView *stage;          ///< dove vive la pagina
@property (nonatomic, strong) NSTextField *counter;
@property (nonatomic, strong) XPButton *backButton;
@property (nonatomic, strong) XPButton *nextButton;
@property (nonatomic, strong) NSTextField *statusLabel;

// Le scelte, tenute qui finché non si applicano.
@property (nonatomic, copy)   NSString *language;
@property (nonatomic, assign) XPThemePreference theme;
@property (nonatomic, copy)   NSString *mysqlPassword;
@property (nonatomic, assign) XPExposureScope exposure;
@property (nonatomic, assign) BOOL checkUpdates;

@property (nonatomic, copy)   NSString *initialLanguage;
@property (nonatomic, assign) XPExposureScope initialExposure;
@property (nonatomic, strong) NSSecureTextField *passwordField;

@end

/// Il wizard aperto, se ce n'è uno. Senza un riferimento forte ARC lo libera
/// appena il metodo finisce e la finestra sparisce da sola.
static XPSetupWizard *sOpen = nil;

@implementation XPSetupWizard

#pragma mark - Presentazione

+ (BOOL)hasRun {
    return [[NSUserDefaults standardUserDefaults] boolForKey:XPSetupDoneKey];
}

+ (void)presentIfNeeded {
    if ([self hasRun]) return;
    [self present];
}

+ (void)present {
    if (sOpen) {
        [sOpen.window makeKeyAndOrderFront:nil];
        return;
    }
    sOpen = [[XPSetupWizard alloc] init];
    [sOpen showWindow:nil];
    [sOpen.window center];
    [NSApp activateIgnoringOtherApps:YES];
}

- (instancetype)init {
    NSWindow *window = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, XPSetupWidth, XPSetupHeight)
                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                    backing:NSBackingStoreBuffered
                      defer:NO];
    window.backgroundColor = [XPTheme bg];
    window.title = NSLocalizedString(@"setup.title", nil);

    self = [super initWithWindow:window];
    if (!self) return nil;

    window.delegate = self;

    _step = 0;
    _language = [self currentLanguageCode];
    _initialLanguage = _language;
    _theme = [XPTheme preference];
    _initialExposure = [XPExposure currentScope];
    // ⛔ La proposta è sempre "solo questo Mac", anche se adesso è aperto.
    // Aprire i progetti alla rete e' una scelta, e una scelta non si eredita
    // da un valore predefinito di Apache che nessuno ha mai deciso.
    _exposure = XPExposureScopeThisMac;
    _checkUpdates = [XPUpdateCheck shared].automatic;

    [self buildChrome];
    [self showStep];
    return self;
}

/// La lingua con cui l'app sta girando adesso.
- (NSString *)currentLanguageCode {
    NSArray *stored = [[NSUserDefaults standardUserDefaults] objectForKey:@"AppleLanguages"];
    NSString *first = [stored isKindOfClass:[NSArray class]] ? stored.firstObject : nil;
    if ([first isKindOfClass:[NSString class]]) {
        for (NSArray<NSString *> *entry in XPLanguages()) {
            if ([first hasPrefix:entry[0]]) return entry[0];
        }
    }
    // Quella che il bundle ha davvero caricato, che è la risposta vera:
    // preferredLocalizations tiene conto di cosa c'è nel bundle.
    NSString *active = [NSBundle mainBundle].preferredLocalizations.firstObject;
    for (NSArray<NSString *> *entry in XPLanguages()) {
        if ([entry[0] isEqualToString:active]) return entry[0];
    }
    return @"en";
}

#pragma mark - Struttura

- (void)buildChrome {
    NSView *content = self.window.contentView;

    self.stage = [[NSView alloc] init];
    self.stage.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:self.stage];

    self.counter = [NSTextField labelWithString:@""];
    self.counter.font = [XPTheme fontSmall];
    self.counter.textColor = [XPTheme textMuted];
    self.counter.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:self.counter];

    self.statusLabel = [NSTextField wrappingLabelWithString:@""];
    self.statusLabel.font = [XPTheme fontSmall];
    self.statusLabel.textColor = [XPTheme textSoft];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:self.statusLabel];

    __weak typeof(self) weakSelf = self;
    self.backButton = [XPButton buttonWithTitle:NSLocalizedString(@"setup.back", nil)
                                          style:XPButtonStyleGhost
                                        onClick:^(XPButton *sender) { [weakSelf goBack]; }];
    self.nextButton = [XPButton buttonWithTitle:NSLocalizedString(@"setup.next", nil)
                                          style:XPButtonStylePrimary
                                        onClick:^(XPButton *sender) { [weakSelf goNext]; }];
    self.backButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.nextButton.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:self.backButton];
    [content addSubview:self.nextButton];

    [NSLayoutConstraint activateConstraints:@[
        [self.stage.topAnchor constraintEqualToAnchor:content.topAnchor constant:XPSetupPadding],
        [self.stage.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:XPSetupPadding],
        [self.stage.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-XPSetupPadding],
        [self.stage.bottomAnchor constraintEqualToAnchor:self.statusLabel.topAnchor constant:-12],

        [self.statusLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:XPSetupPadding],
        [self.statusLabel.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-XPSetupPadding],
        [self.statusLabel.bottomAnchor constraintEqualToAnchor:self.nextButton.topAnchor constant:-12],

        [self.counter.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:XPSetupPadding],
        [self.counter.centerYAnchor constraintEqualToAnchor:self.nextButton.centerYAnchor],

        [self.nextButton.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-XPSetupPadding],
        [self.nextButton.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-XPSetupPadding],
        [self.nextButton.widthAnchor constraintEqualToConstant:130],
        [self.nextButton.heightAnchor constraintEqualToConstant:34],

        [self.backButton.trailingAnchor constraintEqualToAnchor:self.nextButton.leadingAnchor constant:-10],
        [self.backButton.centerYAnchor constraintEqualToAnchor:self.nextButton.centerYAnchor],
        [self.backButton.widthAnchor constraintEqualToConstant:100],
        [self.backButton.heightAnchor constraintEqualToConstant:34],
    ]];
}

#pragma mark - Costruttori di viste

- (NSTextField *)title:(NSString *)text {
    NSTextField *label = [NSTextField wrappingLabelWithString:text];
    label.font = [NSFont systemFontOfSize:20 weight:NSFontWeightSemibold];
    label.textColor = [XPTheme text];
    return label;
}

- (NSTextField *)body:(NSString *)text {
    NSTextField *label = [NSTextField wrappingLabelWithString:text];
    label.font = [XPTheme fontBody];
    label.textColor = [XPTheme textSoft];
    return label;
}

- (NSTextField *)note:(NSString *)text {
    NSTextField *label = [NSTextField wrappingLabelWithString:text];
    label.font = [XPTheme fontSmall];
    label.textColor = [XPTheme textMuted];
    return label;
}

/// La pila verticale in cui ogni pagina mette le sue righe.
- (NSStackView *)page {
    NSStackView *stack = [[NSStackView alloc] init];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 12;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    return stack;
}

- (void)install:(NSStackView *)page {
    for (NSView *view in self.stage.subviews.copy) [view removeFromSuperview];
    [self.stage addSubview:page];
    [NSLayoutConstraint activateConstraints:@[
        [page.topAnchor constraintEqualToAnchor:self.stage.topAnchor],
        [page.leadingAnchor constraintEqualToAnchor:self.stage.leadingAnchor],
        [page.trailingAnchor constraintEqualToAnchor:self.stage.trailingAnchor],
    ]];
    for (NSView *row in page.arrangedSubviews) {
        [row.widthAnchor constraintLessThanOrEqualToAnchor:page.widthAnchor].active = YES;
    }
}

#pragma mark - Le cinque pagine

- (NSInteger)lastStep { return 5; }

- (void)showStep {
    switch (self.step) {
        case 0: [self buildLanguage]; break;
        case 1: [self buildTheme]; break;
        case 2: [self buildPassword]; break;
        case 3: [self buildNetwork]; break;
        case 4: [self buildUpdates]; break;
        default: [self buildFinish]; break;
    }

    self.counter.stringValue = [NSString stringWithFormat:
        NSLocalizedString(@"setup.counter", nil),
        (long)(self.step + 1), (long)(self.lastStep + 1)];
    self.backButton.enabled = self.step > 0;
    self.nextButton.title = self.step == self.lastStep
        ? NSLocalizedString(@"setup.finish", nil)
        : NSLocalizedString(@"setup.next", nil);
}

// ------------------------------------------------------------------ lingua

- (void)buildLanguage {
    NSStackView *page = [self page];
    [page addArrangedSubview:[self title:NSLocalizedString(@"setup.language.title", nil)]];
    [page addArrangedSubview:[self body:NSLocalizedString(@"setup.language.body", nil)]];

    NSPopUpButton *popup = [[NSPopUpButton alloc] init];
    popup.translatesAutoresizingMaskIntoConstraints = NO;
    for (NSArray<NSString *> *entry in XPLanguages()) {
        [popup addItemWithTitle:entry[1]];
        if ([entry[0] isEqualToString:self.language]) {
            [popup selectItemAtIndex:popup.numberOfItems - 1];
        }
    }
    popup.target = self;
    popup.action = @selector(languageChanged:);
    [page addArrangedSubview:popup];
    [popup.widthAnchor constraintEqualToConstant:250].active = YES;

    [page addArrangedSubview:[self note:NSLocalizedString(@"setup.language.note", nil)]];
    [self install:page];
}

- (void)languageChanged:(NSPopUpButton *)sender {
    NSInteger index = sender.indexOfSelectedItem;
    if (index >= 0 && index < (NSInteger)XPLanguages().count) {
        self.language = XPLanguages()[index][0];
    }
}

// ------------------------------------------------------------------ aspetto

- (void)buildTheme {
    NSStackView *page = [self page];
    [page addArrangedSubview:[self title:NSLocalizedString(@"setup.theme.title", nil)]];
    [page addArrangedSubview:[self body:NSLocalizedString(@"setup.theme.body", nil)]];

    NSSegmentedControl *segments = [NSSegmentedControl
        segmentedControlWithLabels:@[[XPTheme nameForPreference:XPThemePreferenceAuto],
                                     [XPTheme nameForPreference:XPThemePreferenceDark],
                                     [XPTheme nameForPreference:XPThemePreferenceLight]]
                      trackingMode:NSSegmentSwitchTrackingSelectOne
                            target:self
                            action:@selector(themeChanged:)];
    segments.translatesAutoresizingMaskIntoConstraints = NO;
    [segments setSelectedSegment:self.theme];
    [page addArrangedSubview:segments];

    [page addArrangedSubview:[self note:NSLocalizedString(@"setup.theme.note", nil)]];
    [self install:page];
}

- (void)themeChanged:(NSSegmentedControl *)sender {
    self.theme = (XPThemePreference)sender.selectedSegment;
    // Il tema si applica subito, non alla fine: è l'unica scelta di cui si può
    // vedere l'effetto mentre la si fa, e vederlo è il modo di sceglierla.
    [XPTheme setPreference:self.theme];
    self.window.backgroundColor = [XPTheme bg];
    [self showStep];
}

// ----------------------------------------------------------------- password

- (void)buildPassword {
    NSStackView *page = [self page];
    [page addArrangedSubview:[self title:NSLocalizedString(@"setup.password.title", nil)]];

    if (![XPDatabase isReachable]) {
        // ⚠️ Il campo si azzera, non si lascia quello di prima. Tornando
        // indietro e poi avanti con MySQL spento, commitCurrentStep leggerebbe
        // un campo che non è più sullo schermo e prenderebbe per buona una
        // password che nessuno sta più vedendo.
        self.passwordField = nil;
        [page addArrangedSubview:[self body:NSLocalizedString(@"setup.password.offline", nil)]];
        [self install:page];
        return;
    }

    // ⚠️ Il testo cambia a seconda di cosa c'è adesso, perché le due
    // situazioni si risolvono in modi diversi: senza password si sta
    // aggiungendo una protezione, con una password si sta cambiando una
    // credenziale che i progetti stanno usando.
    BOOL hasOne = [XPDatabase needsPassword];
    [page addArrangedSubview:[self body:NSLocalizedString(
        hasOne ? @"setup.password.body.existing" : @"setup.password.body.none", nil)]];

    self.passwordField = [[NSSecureTextField alloc] init];
    self.passwordField.translatesAutoresizingMaskIntoConstraints = NO;
    self.passwordField.placeholderString = NSLocalizedString(@"setup.password.placeholder", nil);
    self.passwordField.bezelStyle = NSTextFieldRoundedBezel;
    self.passwordField.stringValue = self.mysqlPassword ?: @"";
    [page addArrangedSubview:self.passwordField];
    [self.passwordField.widthAnchor constraintEqualToConstant:250].active = YES;

    [page addArrangedSubview:[self note:NSLocalizedString(@"setup.password.note", nil)]];
    [self install:page];
}

// --------------------------------------------------------------------- rete

- (void)buildNetwork {
    NSStackView *page = [self page];
    [page addArrangedSubview:[self title:NSLocalizedString(@"setup.network.title", nil)]];

    NSString *address = [XPNetwork localAddress];

    // ⚠️ La frase cambia se il Mac ha un indirizzo pubblico: lì "la rete
    // locale" non è la casa, è internet, e dirlo allo stesso modo sarebbe
    // falso in un punto in cui costa caro.
    NSString *body;
    if (!address) {
        body = NSLocalizedString(@"setup.network.body.offline", nil);
    } else if (![XPNetwork addressIsPrivate:address]) {
        body = [NSString stringWithFormat:
                NSLocalizedString(@"setup.network.body.public", nil), address];
    } else {
        body = [NSString stringWithFormat:
                NSLocalizedString(@"setup.network.body", nil), address];
    }
    [page addArrangedSubview:[self body:body]];

    NSButton *mine = [NSButton radioButtonWithTitle:
        NSLocalizedString(@"exposure.thisMac", nil)
                                             target:self
                                             action:@selector(exposureChanged:)];
    NSButton *lan = [NSButton radioButtonWithTitle:
        NSLocalizedString(@"exposure.network", nil)
                                            target:self
                                            action:@selector(exposureChanged:)];
    mine.tag = XPExposureScopeThisMac;
    lan.tag = XPExposureScopeLocalNetwork;
    mine.state = self.exposure == XPExposureScopeThisMac
               ? NSControlStateValueOn : NSControlStateValueOff;
    lan.state = self.exposure == XPExposureScopeLocalNetwork
              ? NSControlStateValueOn : NSControlStateValueOff;
    [page addArrangedSubview:mine];
    [page addArrangedSubview:lan];

    // Quello che nessuno si aspetta: adesso è già aperto, e la riga lo dice.
    if (self.initialExposure == XPExposureScopeLocalNetwork) {
        [page addArrangedSubview:[self note:NSLocalizedString(@"setup.network.already", nil)]];
    }
    [page addArrangedSubview:[self note:NSLocalizedString(@"setup.network.note", nil)]];
    [self install:page];
}

- (void)exposureChanged:(NSButton *)sender {
    self.exposure = (XPExposureScope)sender.tag;
    [self showStep];
}

// ------------------------------------------------------------ aggiornamenti

- (void)buildUpdates {
    NSStackView *page = [self page];
    [page addArrangedSubview:[self title:NSLocalizedString(@"setup.updates.title", nil)]];
    [page addArrangedSubview:[self body:NSLocalizedString(@"setup.updates.body", nil)]];

    NSButton *yes = [NSButton radioButtonWithTitle:
        NSLocalizedString(@"setup.updates.on", nil)
                                            target:self
                                            action:@selector(updatesChanged:)];
    NSButton *no = [NSButton radioButtonWithTitle:
        NSLocalizedString(@"setup.updates.off", nil)
                                           target:self
                                           action:@selector(updatesChanged:)];
    yes.tag = 1;
    no.tag = 0;
    yes.state = self.checkUpdates ? NSControlStateValueOn : NSControlStateValueOff;
    no.state = self.checkUpdates ? NSControlStateValueOff : NSControlStateValueOn;
    [page addArrangedSubview:yes];
    [page addArrangedSubview:no];

    // ⚠️ Cosa esce e cosa no, scritto per esteso e non riassunto in "nessun
    // dato personale". È l'unica richiesta di rete che l'app fa, e chi legge
    // questa schermata sta decidendo proprio su quella.
    [page addArrangedSubview:[self note:NSLocalizedString(@"setup.updates.note", nil)]];
    [self install:page];
}

- (void)updatesChanged:(NSButton *)sender {
    self.checkUpdates = sender.tag == 1;
    [self showStep];
}

// ------------------------------------------------------------------- saluto

- (void)buildFinish {
    NSStackView *page = [self page];
    [page addArrangedSubview:[self title:NSLocalizedString(@"setup.finish.title", nil)]];

    // Il riepilogo di cosa sta per succedere, non di cosa è successo: le due
    // cose che toccano il sistema non sono ancora state fatte.
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (NSArray<NSString *> *entry in XPLanguages()) {
        if ([entry[0] isEqualToString:self.language]) {
            [lines addObject:[NSString stringWithFormat:@"· %@", entry[1]]];
            break;
        }
    }
    [lines addObject:[NSString stringWithFormat:@"· %@",
                      [XPTheme nameForPreference:self.theme]]];
    if (self.mysqlPassword.length > 0) {
        [lines addObject:[NSString stringWithFormat:@"· %@",
                          NSLocalizedString(@"setup.finish.password", nil)]];
    }
    [lines addObject:[NSString stringWithFormat:@"· %@",
                      [XPExposure nameForScope:self.exposure]]];
    [lines addObject:[NSString stringWithFormat:@"· %@",
                      NSLocalizedString(self.checkUpdates ? @"setup.updates.on"
                                                          : @"setup.updates.off", nil)]];

    [page addArrangedSubview:[self body:[lines componentsJoinedByString:@"\n"]]];

    if (self.exposure != self.initialExposure || self.mysqlPassword.length > 0) {
        [page addArrangedSubview:[self note:NSLocalizedString(@"setup.finish.willAsk", nil)]];
    }

    NSTextField *slogan = [self title:NSLocalizedString(@"setup.slogan", nil)];
    slogan.textColor = [XPTheme accent];
    [page addArrangedSubview:slogan];

    [self install:page];
}

#pragma mark - Navigazione

- (void)goBack {
    if (self.step == 0) return;
    [self commitCurrentStep];
    self.step--;
    [self showStep];
}

- (void)goNext {
    [self commitCurrentStep];
    if (self.step < self.lastStep) {
        self.step++;
        [self showStep];
        return;
    }
    [self apply];
}

/// Prende quello che c'è nei campi della pagina corrente prima di lasciarla.
- (void)commitCurrentStep {
    if (self.step == 2 && self.passwordField) {
        self.mysqlPassword = self.passwordField.stringValue;
    }
}

#pragma mark - Applicazione

- (void)apply {
    self.nextButton.enabled = NO;
    self.backButton.enabled = NO;

    // Lingua e tema non chiedono niente a nessuno: si scrivono subito.
    [XPTheme setPreference:self.theme];
    [XPUpdateCheck shared].automatic = self.checkUpdates;
    BOOL languageChanged = ![self.language isEqualToString:self.initialLanguage];
    if (languageChanged) {
        [[NSUserDefaults standardUserDefaults] setObject:@[self.language]
                                                  forKey:@"AppleLanguages"];
    }
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:XPSetupDoneKey];

    __weak typeof(self) weakSelf = self;
    [self applyPasswordThen:^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        [self applyExposureThen:^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            [self finishAndRelaunch:languageChanged];
        }];
    }];
}

- (void)applyPasswordThen:(void (^)(void))next {
    if (self.mysqlPassword.length == 0 || ![XPDatabase isReachable]) {
        next();
        return;
    }

    self.statusLabel.textColor = [XPTheme textSoft];
    self.statusLabel.stringValue = NSLocalizedString(@"setup.applying.password", nil);

    NSString *password = self.mysqlPassword;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *problem = [XPDatabase setRootPassword:password];
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            if (problem) {
                // ⚠️ Non ci si ferma. La password è una delle cinque domande,
                // non la ragione del wizard: chi ha scritto qualcosa che MySQL
                // rifiuta deve poter finire lo stesso, con il motivo scritto.
                self.statusLabel.textColor = [XPTheme danger];
                self.statusLabel.stringValue = [NSString stringWithFormat:
                    NSLocalizedString(@"setup.failed.password", nil), problem];
            }
            next();
        });
    });
}

- (void)applyExposureThen:(void (^)(void))next {
    if (self.exposure == self.initialExposure) {
        next();
        return;
    }

    self.statusLabel.textColor = [XPTheme textSoft];
    self.statusLabel.stringValue = NSLocalizedString(@"exposure.applying", nil);

    [XPExposure applyScope:self.exposure completion:^(BOOL ok) {
        (void)ok;   // il messaggio l'ha già scritto XPExposure
        next();
    }];
}

/// Chiude, e riavvia l'app se la lingua è cambiata.
///
/// ⚠️ Il catalogo delle stringhe si carica una volta all'avvio: cambiare
/// AppleLanguages a app accesa non cambia una sola etichetta, e senza riavvio
/// il wizard direbbe di aver fatto una cosa che non si vede.
- (void)finishAndRelaunch:(BOOL)languageChanged {
    if (!languageChanged) {
        [self close];
        return;
    }

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = NSLocalizedString(@"setup.relaunch.title", nil);
    alert.informativeText = NSLocalizedString(@"setup.relaunch.body", nil);
    [alert addButtonWithTitle:NSLocalizedString(@"setup.relaunch.now", nil)];
    [alert addButtonWithTitle:NSLocalizedString(@"setup.relaunch.later", nil)];

    if ([alert runModal] != NSAlertFirstButtonReturn) {
        [self close];
        return;
    }

    NSURL *bundle = [NSBundle mainBundle].bundleURL;
    NSWorkspaceOpenConfiguration *config = [NSWorkspaceOpenConfiguration configuration];
    config.createsNewApplicationInstance = YES;
    [[NSWorkspace sharedWorkspace] openApplicationAtURL:bundle
                                          configuration:config
                                      completionHandler:^(NSRunningApplication *app, NSError *error) {
        (void)app; (void)error;
        dispatch_async(dispatch_get_main_queue(), ^{ [NSApp terminate:nil]; });
    }];
}

#pragma mark - Chiusura

- (void)windowWillClose:(NSNotification *)notification {
    // ⚠️ Chiudere dalla crocetta conta come "l'ho visto": senza questo, il
    // wizard tornerebbe a ogni avvio a chi ha deciso di non volerlo.
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:XPSetupDoneKey];
    sOpen = nil;
}

@end
