//
//  XPProjectWizard.m
//

#import "XPProjectWizard.h"
#import "XPActions.h"
#import "XPButton.h"
#import "XPTheme.h"
#import "XPDatabase.h"
#import "XPPhpVersion.h"

static const CGFloat XPWizWidth   = 440;
static const CGFloat XPWizPadding = 22;

@interface XPProjectWizard ()
@property (nonatomic, strong) NSTextField *nameField;
@property (nonatomic, strong) NSTextField *summaryField;
@property (nonatomic, strong) NSTextField *repoField;
@property (nonatomic, strong) NSPopUpButton *phpPopup;
@property (nonatomic, strong) NSArray<XPPhpVersion *> *phpVersions;
@property (nonatomic, strong) NSButton    *databaseCheck;
@property (nonatomic, strong) NSTextField *databaseField;
@property (nonatomic, strong) NSTextField *portField;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) XPButton    *createButton;
@property (nonatomic, strong) XPButton    *cancelButton;
@property (nonatomic, weak)   NSWindow    *parentWindow;
@end

/// Il wizard aperto, se ce n'è uno.
///
/// Serve a due cose insieme: a trattenerlo, perché senza un riferimento forte
/// ARC lo libera appena il metodo finisce e il foglio sparisce da solo; e a
/// impedire che se ne aprano due, che scriverebbero su httpd.conf nello stesso
/// momento assegnandosi la stessa porta.
static XPProjectWizard *sOpenWizard = nil;

@implementation XPProjectWizard

+ (void)presentFromWindow:(NSWindow *)parent {
    if (sOpenWizard) {
        [sOpenWizard.window makeKeyAndOrderFront:nil];
        return;
    }
    sOpenWizard = [[XPProjectWizard alloc] initWithParent:parent];
    [sOpenWizard present];
}

- (instancetype)initWithParent:(NSWindow *)parent {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, XPWizWidth, 400)
                                                   styleMask:NSWindowStyleMaskTitled
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    window.backgroundColor = [XPTheme bg];
    window.title = NSLocalizedString(@"wizard.title", nil);

    self = [super initWithWindow:window];
    if (!self) return nil;

    _parentWindow = parent;
    [self buildInterface];
    return self;
}

#pragma mark - Costruzione

- (void)buildInterface {
    NSStackView *stack = [[NSStackView alloc] init];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 10;
    stack.translatesAutoresizingMaskIntoConstraints = NO;

    [stack addArrangedSubview:[self titleLabel:NSLocalizedString(@"wizard.title", nil)]];
    [stack addArrangedSubview:[self bodyLabel:NSLocalizedString(@"wizard.subtitle", nil)
                                        color:[XPTheme textMuted]]];
    [stack setCustomSpacing:18 afterView:stack.arrangedSubviews.lastObject];

    self.nameField = [self fieldWithPlaceholder:@"my-project"];
    [stack addArrangedSubview:[self labelForField:NSLocalizedString(@"wizard.field.name", nil)]];
    [stack addArrangedSubview:self.nameField];
    [stack addArrangedSubview:[self bodyLabel:NSLocalizedString(@"wizard.hint.name", nil)
                                        color:[XPTheme textMuted]]];
    [stack setCustomSpacing:16 afterView:stack.arrangedSubviews.lastObject];

    self.summaryField = [self fieldWithPlaceholder:
                         NSLocalizedString(@"wizard.field.summary.placeholder", nil)];
    [stack addArrangedSubview:[self labelForField:NSLocalizedString(@"wizard.field.summary", nil)]];
    [stack addArrangedSubview:self.summaryField];
    [stack addArrangedSubview:[self bodyLabel:NSLocalizedString(@"wizard.hint.summary", nil)
                                        color:[XPTheme textMuted]]];
    [stack setCustomSpacing:16 afterView:stack.arrangedSubviews.lastObject];

    self.repoField = [self fieldWithPlaceholder:
                      NSLocalizedString(@"wizard.field.repo.placeholder", nil)];
    [stack addArrangedSubview:[self labelForField:NSLocalizedString(@"wizard.field.repo", nil)]];
    [stack addArrangedSubview:self.repoField];
    [stack setCustomSpacing:16 afterView:stack.arrangedSubviews.lastObject];

    self.portField = [self fieldWithPlaceholder:@"4006"];
    self.portField.stringValue = [NSString stringWithFormat:@"%ld", (long)[XPActions suggestedPort]];
    [stack addArrangedSubview:[self labelForField:NSLocalizedString(@"wizard.field.port", nil)]];
    [stack addArrangedSubview:self.portField];
    [stack addArrangedSubview:[self bodyLabel:NSLocalizedString(@"wizard.hint.port", nil)
                                        color:[XPTheme textMuted]]];
    [stack setCustomSpacing:16 afterView:stack.arrangedSubviews.lastObject];

    // La versione di PHP. L'elenco arriva dopo, perche' trovarlo vuol dire
    // eseguire ogni binario php della macchina: si parte con la voce di attesa
    // e si sostituisce quando la ricerca torna.
    self.phpPopup = [[NSPopUpButton alloc] init];
    self.phpPopup.translatesAutoresizingMaskIntoConstraints = NO;
    [self.phpPopup addItemWithTitle:NSLocalizedString(@"wizard.php.loading", nil)];
    self.phpPopup.enabled = NO;
    [stack addArrangedSubview:[self labelForField:NSLocalizedString(@"wizard.field.php", nil)]];
    [stack addArrangedSubview:self.phpPopup];
    [stack setCustomSpacing:16 afterView:stack.arrangedSubviews.lastObject];

    self.databaseCheck = [NSButton checkboxWithTitle:NSLocalizedString(@"wizard.field.db", nil)
                                              target:self
                                              action:@selector(databaseCheckChanged:)];
    self.databaseCheck.translatesAutoresizingMaskIntoConstraints = NO;
    self.databaseCheck.contentTintColor = [XPTheme text];
    [stack addArrangedSubview:self.databaseCheck];

    self.databaseField = [self fieldWithPlaceholder:@"my_project"];
    self.databaseField.enabled = NO;
    [stack addArrangedSubview:self.databaseField];
    [stack addArrangedSubview:[self bodyLabel:NSLocalizedString(@"wizard.hint.db", nil)
                                        color:[XPTheme textMuted]]];
    [stack setCustomSpacing:18 afterView:stack.arrangedSubviews.lastObject];

    self.statusLabel = [self bodyLabel:@"" color:[XPTheme textSoft]];
    [stack addArrangedSubview:self.statusLabel];

    __weak typeof(self) weakSelf = self;
    self.cancelButton = [XPButton buttonWithTitle:NSLocalizedString(@"btn.cancel", nil)
                                            style:XPButtonStyleGhost
                                          onClick:^(XPButton *sender) { [weakSelf dismiss]; }];
    self.createButton = [XPButton buttonWithTitle:NSLocalizedString(@"wizard.btn.create", nil)
                                            style:XPButtonStylePrimary
                                          onClick:^(XPButton *sender) { [weakSelf create]; }];

    NSStackView *buttons = [[NSStackView alloc] init];
    buttons.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    buttons.distribution = NSStackViewDistributionFillEqually;
    buttons.spacing = 10;
    buttons.translatesAutoresizingMaskIntoConstraints = NO;
    [buttons addArrangedSubview:self.cancelButton];
    [buttons addArrangedSubview:self.createButton];
    [buttons.heightAnchor constraintEqualToConstant:34].active = YES;
    [stack addArrangedSubview:buttons];

    NSView *content = self.window.contentView;
    [content addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:content.topAnchor constant:XPWizPadding],
        [stack.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:XPWizPadding],
        [stack.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-XPWizPadding],
        [stack.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-XPWizPadding],
    ]];

    // Ogni riga larga quanto la pila: senza, i campi si stringono sul testo.
    // ⚠️ La casella di spunta no: allargata, la sua area cliccabile copre tutta
    // la riga e un clic accanto all'etichetta la commuta senza volerlo.
    for (NSView *view in stack.arrangedSubviews) {
        if (view == self.databaseCheck) continue;
        [view.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
    }

    [self loadPhpVersions];
}

#pragma mark - PHP e database

/// Cerca le versioni di PHP fuori dal thread principale.
///
/// ⚠️ +[XPPhpVersion available] esegue ogni binario php che trova: sul main
/// thread la finestra resterebbe bianca per il tempo di due o tre lanci.
- (void)loadPhpVersions {
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<XPPhpVersion *> *versions = [XPPhpVersion available];
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;

            self.phpVersions = versions;
            [self.phpPopup removeAllItems];
            if (versions.count == 0) {
                [self.phpPopup addItemWithTitle:NSLocalizedString(@"wizard.php.none", nil)];
                return;
            }
            for (XPPhpVersion *version in versions) {
                [self.phpPopup addItemWithTitle:version.description];
            }
            // Piu' di una scelta o non e' una scelta: con la sola versione
            // dello stack il menu resta spento invece di fingere un'opzione.
            self.phpPopup.enabled = versions.count > 1;
            [self.phpPopup selectItemAtIndex:0];
        });
    });
}

- (void)databaseCheckChanged:(NSButton *)sender {
    BOOL wanted = sender.state == NSControlStateValueOn;
    self.databaseField.enabled = wanted;

    // Il nome del database si propone dal nome del progetto: i trattini non
    // sono ammessi in un nome di database, quindi diventano trattini bassi.
    if (wanted && self.databaseField.stringValue.length == 0) {
        NSString *name = [self.nameField.stringValue
                          stringByReplacingOccurrencesOfString:@"-" withString:@"_"];
        if (name.length > 0 && ![XPDatabase validationErrorForDatabaseName:name]) {
            self.databaseField.stringValue = name;
        }
    }
    if (wanted) [self.window makeFirstResponder:self.databaseField];
    if (wanted) [self ensureDatabaseAccess];
}

/// Si accerta di poter entrare in MySQL, e se serve chiede la password.
///
/// ⚠️ Va fatto quando si spunta la casella, non alla creazione. Su una
/// installazione passata per il controllo di sicurezza root ha una password, e
/// scoprirlo dopo il clone del repository vorrebbe dire progetto creato e
/// database no, con un messaggio d'errore al posto di una domanda.
- (void)ensureDatabaseAccess {
    if (![XPDatabase isReachable]) {
        [self showProblem:NSLocalizedString(@"db.err.offline", nil)
                  inField:self.databaseField];
        return;
    }

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL needed = [XPDatabase needsPassword];
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self || !needed) return;
            if (self.databaseCheck.state != NSControlStateValueOn) return;   // tolta nel frattempo
            [self askForRootPassword];
        });
    });
}

- (void)askForRootPassword {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = NSLocalizedString(@"db.password.title", nil);
    alert.informativeText = NSLocalizedString(@"db.password.body", nil);
    [alert addButtonWithTitle:NSLocalizedString(@"btn.ok", nil)];
    [alert addButtonWithTitle:NSLocalizedString(@"btn.cancel", nil)];

    // ⚠️ NSSecureTextField, non NSTextField: la password non si mostra a
    // schermo e non finisce nel dettatore di sistema.
    NSSecureTextField *input = [[NSSecureTextField alloc]
                                initWithFrame:NSMakeRect(0, 0, 260, 24)];
    alert.accessoryView = input;
    [alert layout];
    [alert.window makeFirstResponder:input];

    NSModalResponse response = [alert runModal];
    if (response != NSAlertFirstButtonReturn) {
        // Rinunciando alla password si rinuncia al database: la casella torna
        // giù invece di lasciare una scelta che poi fallirebbe.
        self.databaseCheck.state = NSControlStateValueOff;
        [self databaseCheckChanged:self.databaseCheck];
        return;
    }

    NSString *password = input.stringValue;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL works = [XPDatabase passwordWorks:password];
        if (works) [XPDatabase storePassword:password];
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            if (works) {
                self.statusLabel.textColor = [XPTheme textSoft];
                self.statusLabel.stringValue = NSLocalizedString(@"db.password.saved", nil);
            } else {
                [self showProblem:NSLocalizedString(@"db.password.wrong", nil)
                          inField:self.databaseField];
                [self askForRootPassword];
            }
        });
    });
}

#pragma mark - Costruttori di viste

- (NSTextField *)titleLabel:(NSString *)text {
    NSTextField *label = [NSTextField labelWithString:text];
    label.font = [XPTheme fontTitle];
    label.textColor = [XPTheme text];
    return label;
}

- (NSTextField *)labelForField:(NSString *)text {
    NSTextField *label = [NSTextField labelWithString:text];
    label.font = [NSFont systemFontOfSize:[XPTheme fontSmall].pointSize weight:NSFontWeightMedium];
    label.textColor = [XPTheme textSoft];
    return label;
}

- (NSTextField *)bodyLabel:(NSString *)text color:(NSColor *)color {
    NSTextField *label = [NSTextField wrappingLabelWithString:text];
    label.font = [XPTheme fontSmall];
    label.textColor = color;
    label.selectable = NO;
    return label;
}

- (NSTextField *)fieldWithPlaceholder:(NSString *)placeholder {
    NSTextField *field = [[NSTextField alloc] init];
    field.placeholderString = placeholder;
    field.font = [XPTheme fontBody];
    field.bezelStyle = NSTextFieldRoundedBezel;
    field.translatesAutoresizingMaskIntoConstraints = NO;
    [field.heightAnchor constraintEqualToConstant:24].active = YES;
    return field;
}

#pragma mark - Presentazione

- (void)present {
    [self.window layoutIfNeeded];
    NSSize fitting = [self.window.contentView fittingSize];
    [self.window setContentSize:NSMakeSize(XPWizWidth, fitting.height)];

    if (self.parentWindow) {
        [self.parentWindow beginSheet:self.window completionHandler:nil];
    } else {
        [NSApp activateIgnoringOtherApps:YES];
        [self.window center];
        [self.window makeKeyAndOrderFront:nil];
    }
    [self.window makeFirstResponder:self.nameField];
}

- (void)dismiss {
    if (self.parentWindow) {
        [self.parentWindow endSheet:self.window];
    }
    [self.window orderOut:nil];
    if (sOpenWizard == self) sOpenWizard = nil;
}

#pragma mark - Azione

- (void)create {
    NSString *name = self.nameField.stringValue;
    NSString *repo = self.repoField.stringValue;
    NSInteger port = self.portField.stringValue.integerValue;

    // Si valida qui per poter indicare il campo sbagliato mentre la finestra è
    // ancora aperta. XPActions ricontrolla comunque tutto prima di scrivere.
    NSString *problem = [XPActions validationErrorForProjectName:name];
    if (problem) {
        [self showProblem:problem inField:self.nameField];
        return;
    }
    problem = [XPActions validationErrorForPort:port];
    if (problem) {
        [self showProblem:problem inField:self.portField];
        return;
    }

    NSString *database = nil;
    if (self.databaseCheck.state == NSControlStateValueOn) {
        database = [self.databaseField.stringValue stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        problem = [XPDatabase validationErrorForDatabaseName:database];
        if (problem) {
            [self showProblem:problem inField:self.databaseField];
            return;
        }
        // ⚠️ Si controlla prima di cominciare, non a meta'. Scoprire che il
        // server e' giu' dopo aver clonato il repository e scritto il virtual
        // host lascerebbe il progetto fatto e il database no, ed e' lo stato
        // piu' scomodo da rimettere a posto a mano.
        if (![XPDatabase isReachable]) {
            [self showProblem:NSLocalizedString(@"db.err.offline", nil)
                      inField:self.databaseField];
            return;
        }
        if ([XPDatabase databaseExists:database]) {
            [self showProblem:NSLocalizedString(@"db.err.exists", nil)
                      inField:self.databaseField];
            return;
        }
    }

    XPPhpVersion *phpVersion = nil;
    NSInteger phpIndex = self.phpPopup.indexOfSelectedItem;
    if (phpIndex >= 0 && phpIndex < (NSInteger)self.phpVersions.count) {
        phpVersion = self.phpVersions[phpIndex];
    }

    self.createButton.enabled = NO;
    self.cancelButton.enabled = NO;
    self.statusLabel.textColor = [XPTheme textSoft];
    self.statusLabel.stringValue = NSLocalizedString(@"wizard.progress.creating", nil);

    // I messaggi di avanzamento arrivano come notifica, la stessa che aggiorna
    // la barra della finestra principale: qui si mostrano anche nel foglio,
    // che altrimenti la coprirebbe.
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(actionDidReport:)
                                                 name:XPActionMessageNotification
                                               object:nil];

    __weak typeof(self) weakSelf = self;
    [[XPActions shared] createProjectNamed:name
                                   summary:self.summaryField.stringValue
                                repository:repo
                                      port:port
                                phpVersion:phpVersion
                                  database:database
                                completion:^(BOOL ok) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;

        [[NSNotificationCenter defaultCenter] removeObserver:self
                                                        name:XPActionMessageNotification
                                                      object:nil];
        if (ok) {
            [self dismiss];
        } else {
            self.createButton.enabled = YES;
            self.cancelButton.enabled = YES;
        }
    }];
}

- (void)actionDidReport:(NSNotification *)note {
    BOOL isError = [note.userInfo[@"isError"] boolValue];
    self.statusLabel.textColor = isError ? [XPTheme danger] : [XPTheme textSoft];
    self.statusLabel.stringValue = note.userInfo[@"message"] ?: @"";
}

- (void)showProblem:(NSString *)problem inField:(NSTextField *)field {
    self.statusLabel.textColor = [XPTheme danger];
    self.statusLabel.stringValue = problem;
    [self.window makeFirstResponder:field];
    NSBeep();
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end
