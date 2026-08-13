//
//  XPProjectWizard.m
//

#import "XPProjectWizard.h"
#import "XPActions.h"
#import "XPButton.h"
#import "XPTheme.h"

static const CGFloat XPWizWidth   = 440;
static const CGFloat XPWizPadding = 22;

@interface XPProjectWizard ()
@property (nonatomic, strong) NSTextField *nameField;
@property (nonatomic, strong) NSTextField *repoField;
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
    for (NSView *view in stack.arrangedSubviews) {
        [view.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
    }
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
    [[XPActions shared] createProjectNamed:name repository:repo port:port
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
