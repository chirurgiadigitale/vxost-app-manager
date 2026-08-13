//
//  XPMainWindowController.m
//

#import "XPMainWindowController.h"
#import "XPTheme.h"
#import "XPPaths.h"
#import "XPButton.h"
#import "XPService.h"
#import "XPServiceMonitor.h"
#import "XPServiceRowView.h"
#import "XPActions.h"
#import "XPLogWindowController.h"
#import "XPVirtualHost.h"
#import "XPVHostRowView.h"
#import "XPTimerSectionView.h"
#import "XPTracker.h"

static const CGFloat XPWinWidth   = 620.0;
static const CGFloat XPWinPadding = 22.0;

#pragma mark - Sfondo

/// Sfondo della finestra nei colori del design system.
@interface XPMainContentView : NSView
@end

@implementation XPMainContentView
- (void)drawRect:(NSRect)dirtyRect {
    [[XPTheme bg] setFill];
    NSRectFill(self.bounds);
}
@end

#pragma mark -

@interface XPMainWindowController ()
@property (nonatomic, strong) NSStackView *rootStack;
@property (nonatomic, strong) NSMutableArray<XPServiceRowView *> *rows;
@property (nonatomic, strong) XPButton *startAllButton;
@property (nonatomic, strong) XPButton *stopAllButton;
@property (nonatomic, strong) XPButton *restartButton;
@property (nonatomic, strong) NSTextField *statusBadge;
@property (nonatomic, strong) NSTextField *messageLabel;
@property (nonatomic, strong) NSTimer *messageTimer;
@property (nonatomic, strong) NSTextField *hostsSummary;
@property (nonatomic, strong) XPTimerSectionView *timerSection;
@end


@implementation XPMainWindowController

+ (instancetype)shared {
    static XPMainWindowController *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[XPMainWindowController alloc] init]; });
    return shared;
}

- (instancetype)init {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, XPWinWidth, 760)
                                                   styleMask:(NSWindowStyleMaskTitled |
                                                              NSWindowStyleMaskClosable |
                                                              NSWindowStyleMaskMiniaturizable |
                                                              NSWindowStyleMaskResizable)
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    window.title = @"VXOST";
    window.releasedWhenClosed = NO;
    window.titlebarAppearsTransparent = YES;
    window.backgroundColor = [XPTheme bg];
    window.collectionBehavior |= NSWindowCollectionBehaviorFullScreenPrimary;
    window.minSize = NSMakeSize(560, 460);
    [window center];

    if ((self = [super initWithWindow:window])) {
        _rows = [NSMutableArray array];
        [self buildInterface];

        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        [center addObserver:self selector:@selector(servicesDidChange:)
                       name:XPServicesDidChangeNotification object:nil];
        [center addObserver:self selector:@selector(actionDidReport:)
                       name:XPActionMessageNotification object:nil];
        [center addObserver:self selector:@selector(windowWillClose:)
                       name:NSWindowWillCloseNotification object:window];
        [center addObserver:self selector:@selector(themeDidChange:)
                       name:XPThemeDidChangeNotification object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)windowWillClose:(NSNotification *)note {
    [[XPServiceMonitor shared] setFastPolling:NO];
}

/// Al cambio di tema la finestra si ricostruisce da capo: i colori sono
/// assegnati alla creazione e la finestra non contiene dati inseriti
/// dall'utente.
- (void)themeDidChange:(NSNotification *)note {
    self.window.backgroundColor = [XPTheme bg];
    [self.rows removeAllObjects];
    [self buildInterface];
    [self refresh];
}

#pragma mark - Costruzione
//
// Tutta la finestra è costruita con Auto Layout, su pile annidate. Tre cose
// che prima andavano fatte a mano ora vengono da sé: il contenuto segue la
// larghezza fino a tutto schermo, le etichette più lunghe delle altre lingue
// trovano posto, e in urdu NSStackView specchia l'ordine senza che nessuno
// debba invertire coordinate.

- (void)buildInterface {
    XPMainContentView *content = [[XPMainContentView alloc] init];
    self.window.contentView = content;

    // La finestra può essere rimpicciolita sotto l'altezza del contenuto:
    // senza scorrimento le sezioni in fondo diventerebbero irraggiungibili.
    NSScrollView *scroll = [[NSScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.hasVerticalScroller = YES;
    scroll.drawsBackground = NO;
    scroll.borderType = NSNoBorder;
    [content addSubview:scroll];

    NSView *document = [[NSView alloc] init];
    document.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.documentView = document;

    self.rootStack = [[NSStackView alloc] init];
    self.rootStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.rootStack.alignment = NSLayoutAttributeLeading;
    self.rootStack.spacing = 8;
    self.rootStack.translatesAutoresizingMaskIntoConstraints = NO;
    [document addSubview:self.rootStack];

    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:content.topAnchor constant:34],
        [scroll.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],

        [document.widthAnchor constraintEqualToAnchor:scroll.widthAnchor],

        [self.rootStack.topAnchor constraintEqualToAnchor:document.topAnchor],
        [self.rootStack.leadingAnchor constraintEqualToAnchor:document.leadingAnchor
                                                     constant:XPWinPadding],
        [self.rootStack.trailingAnchor constraintEqualToAnchor:document.trailingAnchor
                                                      constant:-XPWinPadding],
        [self.rootStack.bottomAnchor constraintEqualToAnchor:document.bottomAnchor
                                                    constant:-XPWinPadding],
    ]];

    [self addHeader];
    [self addSection:NSLocalizedString(@"section.services", nil) accessory:self.statusBadge];
    [self addServiceRows];
    [self addSection:NSLocalizedString(@"section.control", nil) accessory:nil];
    [self addControlButtons];
    [self addProjectsSection];
    [self addSection:NSLocalizedString(@"section.timer", nil) accessory:nil];
    [self addTimerSection];
    [self addSection:NSLocalizedString(@"section.links", nil) accessory:nil];
    [self addShortcuts];
    [self addSection:NSLocalizedString(@"section.tools", nil) accessory:nil];
    [self addTools];
    [self addSection:NSLocalizedString(@"section.config", nil) accessory:nil];
    [self addConfigButtons];
    [self addSection:NSLocalizedString(@"section.appearance", nil) accessory:nil];
    [self addThemePicker];
    [self addMessageBar];

    // Ogni sezione occupa tutta la larghezza: è ciò che fa allargare davvero
    // il contenuto a tutto schermo invece di lasciarlo in colonna.
    for (NSView *view in self.rootStack.arrangedSubviews) {
        [view.widthAnchor constraintEqualToAnchor:self.rootStack.widthAnchor].active = YES;
    }
}

- (void)addHeader {
    NSView *header = [[NSView alloc] init];
    header.translatesAutoresizingMaskIntoConstraints = NO;

    NSImageView *iconView = [[NSImageView alloc] init];
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    NSString *iconPath = [[NSBundle mainBundle] pathForResource:@"AppIcon" ofType:@"icns"];
    if (iconPath) iconView.image = [[NSImage alloc] initWithContentsOfFile:iconPath];
    iconView.imageScaling = NSImageScaleProportionallyUpOrDown;

    NSTextField *title = [self labelWithFont:[NSFont systemFontOfSize:22 weight:NSFontWeightBold]
                                       color:[XPTheme text]];
    title.stringValue = @"VXOST";

    NSString *appVersion = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    NSString *vxostVersion = [XPPaths vxostVersion];
    NSTextField *subtitle = [self labelWithFont:[XPTheme fontSmall] color:[XPTheme textMuted]];
    subtitle.stringValue = vxostVersion
        ? [NSString stringWithFormat:NSLocalizedString(@"app.subtitle.full", nil),
           vxostVersion, appVersion]
        : [NSString stringWithFormat:NSLocalizedString(@"app.subtitle.short", nil), appVersion];

    self.statusBadge = [self labelWithFont:[XPTheme fontBody] color:[XPTheme textMuted]];
    self.statusBadge.alignment = NSTextAlignmentRight;

    [header addSubview:iconView];
    [header addSubview:title];
    [header addSubview:subtitle];

    [NSLayoutConstraint activateConstraints:@[
        [header.heightAnchor constraintEqualToConstant:52],
        [iconView.leadingAnchor constraintEqualToAnchor:header.leadingAnchor],
        [iconView.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [iconView.widthAnchor constraintEqualToConstant:44],
        [iconView.heightAnchor constraintEqualToConstant:44],

        [title.leadingAnchor constraintEqualToAnchor:iconView.trailingAnchor constant:12],
        [title.topAnchor constraintEqualToAnchor:header.topAnchor constant:2],

        [subtitle.leadingAnchor constraintEqualToAnchor:iconView.trailingAnchor constant:12],
        [subtitle.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:2],
        [subtitle.trailingAnchor constraintLessThanOrEqualToAnchor:header.trailingAnchor],
    ]];

    [self.rootStack addArrangedSubview:header];
}

/// Titolo di sezione, con un'etichetta facoltativa allineata al bordo finale.
- (void)addSection:(NSString *)text accessory:(NSView *)accessory {
    NSView *row = [[NSView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    NSTextField *label = [self labelWithFont:[NSFont systemFontOfSize:10
                                                               weight:NSFontWeightSemibold]
                                       color:[XPTheme textMuted]];
    label.attributedStringValue = [[NSAttributedString alloc]
        initWithString:[text uppercaseString]
            attributes:@{NSFontAttributeName: [NSFont systemFontOfSize:10
                                                                weight:NSFontWeightSemibold],
                         NSForegroundColorAttributeName: [XPTheme textMuted],
                         NSKernAttributeName: @1.2}];
    [row addSubview:label];

    [NSLayoutConstraint activateConstraints:@[
        [row.heightAnchor constraintEqualToConstant:26],
        [label.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [label.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-4],
    ]];

    if (accessory) {
        accessory.translatesAutoresizingMaskIntoConstraints = NO;
        [row addSubview:accessory];
        [NSLayoutConstraint activateConstraints:@[
            [accessory.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
            [accessory.centerYAnchor constraintEqualToAnchor:label.centerYAnchor],
            [accessory.leadingAnchor constraintGreaterThanOrEqualToAnchor:label.trailingAnchor
                                                                 constant:8],
        ]];
    }

    [self.rootStack addArrangedSubview:row];
}

- (void)addServiceRows {
    for (XPService *service in [XPServiceMonitor shared].services) {
        XPServiceRowView *row = [[XPServiceRowView alloc] initWithService:service];
        row.translatesAutoresizingMaskIntoConstraints = NO;
        [row.heightAnchor constraintEqualToConstant:56].active = YES;
        row.onToggle = ^(XPService *s) { [[XPActions shared] toggleService:s]; };
        row.onReload = ^(XPService *s) { [[XPActions shared] reloadService:s]; };
        [self.rootStack addArrangedSubview:row];
        [self.rows addObject:row];
    }
}

- (void)addControlButtons {
    NSArray *specs = @[
        @[NSLocalizedString(@"btn.startAll", nil), @(XPButtonStylePrimary), @"play.fill"],
        @[NSLocalizedString(@"btn.stopAll", nil),  @(XPButtonStyleGhost),   @"stop.fill"],
        @[NSLocalizedString(@"btn.restart", nil),  @(XPButtonStyleGhost),   @"arrow.clockwise"],
    ];

    NSMutableArray<NSView *> *buttons = [NSMutableArray array];
    for (NSUInteger i = 0; i < specs.count; i++) {
        NSArray *spec = specs[i];
        XPButton *button = [XPButton buttonWithTitle:spec[0]
                                               style:[spec[1] integerValue]
                                             onClick:^(XPButton *b) {
            if (i == 0)      [[XPActions shared] startAll];
            else if (i == 1) [[XPActions shared] stopAll];
            else             [[XPActions shared] restartAll];
        }];
        button.symbolName = spec[2];
        [buttons addObject:button];
        if (i == 0) self.startAllButton = button;
        if (i == 1) self.stopAllButton = button;
        if (i == 2) self.restartButton = button;
    }

    [self.rootStack addArrangedSubview:[self equalRowWithViews:buttons height:34]];
}

- (void)addProjectsSection {
    NSArray<XPVirtualHost *> *hosts = [XPVirtualHost allHosts];
    if (hosts.count == 0) return;

    NSUInteger listening = 0, disabled = 0;
    for (XPVirtualHost *host in hosts) {
        if (host.state == XPVHostStateListening) listening++;
        else if (host.state == XPVHostStateDisabled) disabled++;
    }

    self.hostsSummary = [self labelWithFont:[XPTheme fontSmall] color:[XPTheme textMuted]];
    self.hostsSummary.alignment = NSTextAlignmentRight;
    self.hostsSummary.stringValue = (disabled > 0)
        ? [NSString stringWithFormat:NSLocalizedString(@"vhost.summary.withDisabled", nil),
           (unsigned long)listening, (unsigned long)disabled]
        : [NSString stringWithFormat:NSLocalizedString(@"vhost.summary", nil),
           (unsigned long)listening];

    [self addSection:NSLocalizedString(@"section.projects", nil) accessory:self.hostsSummary];

    for (XPVirtualHost *host in hosts) {
        XPVHostRowView *row = [[XPVHostRowView alloc] initWithHost:host];
        row.translatesAutoresizingMaskIntoConstraints = NO;
        [row.heightAnchor constraintEqualToConstant:30].active = YES;
        [self.rootStack addArrangedSubview:row];
    }
}

- (void)addTimerSection {
    self.timerSection = [[XPTimerSectionView alloc] init];
    [self.rootStack addArrangedSubview:self.timerSection];
}

- (void)addShortcuts {
    NSArray *specs = @[
        @[NSLocalizedString(@"link.dashboard", nil),    @"safari"],
        @[@"phpMyAdmin",                                @"cylinder.split.1x2"],
        @[NSLocalizedString(@"link.htdocsFolder", nil), @"folder"],
        @[NSLocalizedString(@"link.viewLogs", nil),     @"doc.text.magnifyingglass"],
    ];
    [self addGrid:specs columns:2 height:32 handler:^(NSUInteger index) {
        switch (index) {
            case 0: [[XPActions shared] openDashboard]; break;
            case 1: [[XPActions shared] openPhpMyAdmin]; break;
            case 2: [[XPActions shared] openHtdocs]; break;
            default: [[XPLogWindowController shared] showWindowAndReload]; break;
        }
    }];
}

- (void)addTools {
    NSArray *specs = @[
        @[NSLocalizedString(@"tool.enableSSL", nil),  @"lock.fill"],
        @[NSLocalizedString(@"tool.disableSSL", nil), @"lock.open"],
        @[NSLocalizedString(@"tool.security", nil),   @"checkmark.shield"],
        @[NSLocalizedString(@"tool.backup", nil),     @"externaldrive.fill"],
    ];
    [self addGrid:specs columns:2 height:32 handler:^(NSUInteger index) {
        switch (index) {
            case 0: [[XPActions shared] enableSSL]; break;
            case 1: [[XPActions shared] disableSSL]; break;
            case 2: [[XPActions shared] runSecurityCheck]; break;
            default: [[XPActions shared] runBackup]; break;
        }
    }];
}

- (void)addConfigButtons {
    NSArray<NSDictionary *> *files = [XPPaths configFiles];
    if (files.count == 0) {
        NSTextField *empty = [self labelWithFont:[XPTheme fontSmall] color:[XPTheme textMuted]];
        empty.stringValue = NSLocalizedString(@"config.none", nil);
        [self.rootStack addArrangedSubview:empty];
        return;
    }

    NSMutableArray *specs = [NSMutableArray array];
    for (NSDictionary *file in files) [specs addObject:@[file[@"title"], @""]];

    [self addGrid:specs columns:3 height:28 handler:^(NSUInteger index) {
        [[XPActions shared] revealFile:files[index][@"path"]];
    }];

    XPButton *folder = [XPButton buttonWithTitle:NSLocalizedString(@"link.vxostFolder", nil)
                                            style:XPButtonStyleQuiet
                                          onClick:^(XPButton *b) {
        [[XPActions shared] openVxostFolder];
    }];
    folder.symbolName = @"folder.badge.gearshape";
    folder.translatesAutoresizingMaskIntoConstraints = NO;

    NSView *row = [[NSView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:folder];
    [NSLayoutConstraint activateConstraints:@[
        [row.heightAnchor constraintEqualToConstant:28],
        [folder.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [folder.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [folder.widthAnchor constraintEqualToConstant:210],
    ]];
    [self.rootStack addArrangedSubview:row];
}

- (void)addThemePicker {
    NSSegmentedControl *picker = [NSSegmentedControl
        segmentedControlWithLabels:@[NSLocalizedString(@"theme.auto", nil),
                                     NSLocalizedString(@"theme.dark", nil),
                                     NSLocalizedString(@"theme.light", nil)]
                      trackingMode:NSSegmentSwitchTrackingSelectOne
                            target:self
                            action:@selector(themeChanged:)];
    picker.translatesAutoresizingMaskIntoConstraints = NO;
    picker.selectedSegment = [XPTheme preference];

    NSTextField *hint = [self labelWithFont:[XPTheme fontSmall] color:[XPTheme textMuted]];
    hint.stringValue = NSLocalizedString(@"theme.hint", nil);

    NSView *row = [[NSView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:picker];
    [row addSubview:hint];

    [NSLayoutConstraint activateConstraints:@[
        [row.heightAnchor constraintEqualToConstant:30],
        [picker.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [picker.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [picker.widthAnchor constraintGreaterThanOrEqualToConstant:250],

        [hint.leadingAnchor constraintEqualToAnchor:picker.trailingAnchor constant:12],
        [hint.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [hint.trailingAnchor constraintLessThanOrEqualToAnchor:row.trailingAnchor],
    ]];

    [self.rootStack addArrangedSubview:row];
}

- (void)themeChanged:(NSSegmentedControl *)sender {
    [XPTheme setPreference:(XPThemePreference)sender.selectedSegment];
}

- (void)addMessageBar {
    NSBox *line = [[NSBox alloc] init];
    line.translatesAutoresizingMaskIntoConstraints = NO;
    line.boxType = NSBoxCustom;
    line.borderWidth = 0;
    line.fillColor = [XPTheme border];
    [line.heightAnchor constraintEqualToConstant:1].active = YES;
    [self.rootStack addArrangedSubview:line];

    self.messageLabel = [self labelWithFont:[XPTheme fontSmall] color:[XPTheme textMuted]];
    self.messageLabel.alignment = NSTextAlignmentNatural;
    [self.messageLabel.heightAnchor constraintEqualToConstant:16].active = YES;
    [self.rootStack addArrangedSubview:self.messageLabel];
}

#pragma mark - Costruttori di righe

/// Riga di viste tutte della stessa larghezza, che crescono con la finestra.
- (NSView *)equalRowWithViews:(NSArray<NSView *> *)views height:(CGFloat)height {
    NSStackView *stack = [NSStackView stackViewWithViews:views];
    stack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    stack.distribution = NSStackViewDistributionFillEqually;
    stack.spacing = 10;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    for (NSView *view in views) {
        [view.heightAnchor constraintEqualToConstant:height].active = YES;
    }
    return stack;
}

/// Griglia di pulsanti a N colonne.
- (void)addGrid:(NSArray *)specs
        columns:(NSUInteger)columns
         height:(CGFloat)height
        handler:(void (^)(NSUInteger index))handler {

    NSMutableArray<NSView *> *rowViews = [NSMutableArray array];

    for (NSUInteger i = 0; i < specs.count; i++) {
        NSArray *spec = specs[i];
        XPButton *button = [XPButton buttonWithTitle:spec[0]
                                               style:XPButtonStyleGhost
                                             onClick:^(XPButton *b) { handler(i); }];
        if ([spec[1] length] > 0) button.symbolName = spec[1];
        [rowViews addObject:button];

        BOOL rowFull = (rowViews.count == columns);
        BOOL last = (i == specs.count - 1);
        if (rowFull || last) {
            // L'ultima riga incompleta si riempie di spazi vuoti, altrimenti i
            // suoi pulsanti si allargherebbero più di quelli sopra.
            while (rowViews.count < columns) {
                NSView *filler = [[NSView alloc] init];
                filler.translatesAutoresizingMaskIntoConstraints = NO;
                [rowViews addObject:filler];
            }
            [self.rootStack addArrangedSubview:[self equalRowWithViews:rowViews height:height]];
            rowViews = [NSMutableArray array];
        }
    }
}

- (NSTextField *)labelWithFont:(NSFont *)font color:(NSColor *)color {
    NSTextField *label = [[NSTextField alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.editable = NO; label.selectable = NO; label.bordered = NO;
    label.drawsBackground = NO;
    label.font = font; label.textColor = color;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    label.stringValue = @"";
    return label;
}

#pragma mark - Presentazione

- (void)present {
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    [[XPActions shared] setPresentingWindow:self.window];
    [[XPServiceMonitor shared] setFastPolling:YES];
    [[XPServiceMonitor shared] refreshNow];
    [self refresh];
}

#pragma mark - Aggiornamento

- (void)servicesDidChange:(NSNotification *)note {
    [self refresh];
}

- (void)refresh {
    for (XPServiceRowView *row in self.rows) [row refresh];

    XPServiceMonitor *monitor = [XPServiceMonitor shared];
    BOOL busy = monitor.anyBusy;

    self.startAllButton.enabled = !busy && !monitor.allRunning;
    self.stopAllButton.enabled  = !busy && monitor.anyRunning;
    self.restartButton.enabled  = !busy && monitor.anyRunning;

    NSString *text;
    NSColor *color;
    if (busy)                    { text = NSLocalizedString(@"status.busy", nil);       color = [XPTheme amber]; }
    else if (monitor.allRunning) { text = NSLocalizedString(@"status.allRunning", nil); color = [XPTheme running]; }
    else if (monitor.anyRunning) { text = NSLocalizedString(@"status.partial", nil);    color = [XPTheme amber]; }
    else                         { text = NSLocalizedString(@"status.allStopped", nil); color = [XPTheme textMuted]; }

    self.statusBadge.stringValue = text;
    self.statusBadge.textColor = color;
}

- (void)actionDidReport:(NSNotification *)note {
    NSString *message = note.userInfo[@"message"];
    BOOL isError = [note.userInfo[@"isError"] boolValue];

    self.messageLabel.stringValue = message ?: @"";
    self.messageLabel.textColor = isError ? [XPTheme danger] : [XPTheme textMuted];

    [self.messageTimer invalidate];
    if (message.length > 0) {
        self.messageTimer = [NSTimer scheduledTimerWithTimeInterval:(isError ? 12.0 : 6.0)
                                                            repeats:NO
                                                              block:^(NSTimer *t) {
            self.messageLabel.stringValue = @"";
        }];
    }
}

@end
