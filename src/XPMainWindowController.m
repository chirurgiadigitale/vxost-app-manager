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

static const CGFloat XPWinWidth   = 560.0;
static const CGFloat XPWinPadding = 22.0;
static const CGFloat XPRowHeight  = 56.0;

#pragma mark - Vista di sfondo

/// Sfondo della finestra nei colori del design system, con layout dall'alto.
@interface XPMainContentView : NSView
@end

@implementation XPMainContentView
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)dirtyRect {
    [[XPTheme bg] setFill];
    NSRectFill(self.bounds);
}
@end

#pragma mark -

@interface XPMainWindowController ()
@property (nonatomic, strong) NSMutableArray<XPServiceRowView *> *rows;
@property (nonatomic, strong) XPButton *startAllButton;
@property (nonatomic, strong) XPButton *stopAllButton;
@property (nonatomic, strong) XPButton *restartButton;
@property (nonatomic, strong) NSTextField *statusBadge;
@property (nonatomic, strong) NSTextField *messageLabel;
@property (nonatomic, strong) NSTimer *messageTimer;
@end


@implementation XPMainWindowController

+ (instancetype)shared {
    static XPMainWindowController *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[XPMainWindowController alloc] init]; });
    return shared;
}

- (instancetype)init {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, XPWinWidth, 700)
                                                   styleMask:(NSWindowStyleMaskTitled |
                                                              NSWindowStyleMaskClosable |
                                                              NSWindowStyleMaskMiniaturizable)
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    window.title = @"XAMPP";
    window.releasedWhenClosed = NO;
    window.titlebarAppearsTransparent = YES;
    window.backgroundColor = [XPTheme bg];
    [window center];

    if ((self = [super initWithWindow:window])) {
        _rows = [NSMutableArray array];
        [self buildInterface];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(servicesDidChange:)
                                                     name:XPServicesDidChangeNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(actionDidReport:)
                                                     name:XPActionMessageNotification
                                                   object:nil];
        // Con la finestra chiusa non serve più il polling rapido: lo stato
        // resta aggiornato alla cadenza lenta per la sola icona.
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(windowWillClose:)
                                                     name:NSWindowWillCloseNotification
                                                   object:window];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(themeDidChange:)
                                                     name:XPThemeDidChangeNotification
                                                   object:nil];
    }
    return self;
}

- (void)windowWillClose:(NSNotification *)note {
    [[XPServiceMonitor shared] setFastPolling:NO];
}

/// Al cambio di tema la finestra si ricostruisce da capo.
///
/// Le etichette hanno il colore assegnato alla creazione: aggiornarle una per
/// una significherebbe tenere un elenco di riferimenti sempre allineato al
/// layout. La finestra non contiene dati inseriti dall'utente, quindi
/// ricostruirla è più semplice e non perde nulla.
- (void)themeDidChange:(NSNotification *)note {
    self.window.backgroundColor = [XPTheme bg];
    [self.rows removeAllObjects];
    [self buildInterface];
    [self refresh];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Costruzione

- (void)buildInterface {
    XPMainContentView *content = [[XPMainContentView alloc] initWithFrame:
                                  NSMakeRect(0, 0, XPWinWidth, 700)];
    self.window.contentView = content;

    CGFloat y = 34.0;   // spazio per la barra del titolo trasparente

    y = [self addHeaderTo:content atY:y];
    y = [self addSectionTitle:@"Servizi" to:content atY:y];
    y = [self addServiceRowsTo:content atY:y];
    y = [self addSectionTitle:@"Controllo" to:content atY:y];
    y = [self addControlButtonsTo:content atY:y];
    y = [self addSectionTitle:@"Collegamenti" to:content atY:y];
    y = [self addShortcutsTo:content atY:y];
    y = [self addSectionTitle:@"Strumenti" to:content atY:y];
    y = [self addToolsTo:content atY:y];
    y = [self addSectionTitle:@"Configurazione" to:content atY:y];
    y = [self addConfigButtonsTo:content atY:y];
    y = [self addSectionTitle:@"Aspetto" to:content atY:y];
    y = [self addThemePickerTo:content atY:y];
    y = [self addMessageBarTo:content atY:y];

    // La finestra si adatta al contenuto invece di imporgli un'altezza fissa.
    NSRect frame = self.window.frame;
    CGFloat delta = y - NSHeight(content.bounds);
    frame.size.height += delta;
    frame.origin.y -= delta;
    [self.window setFrame:frame display:NO];
    content.frame = NSMakeRect(0, 0, XPWinWidth, y);
}

- (CGFloat)addHeaderTo:(NSView *)content atY:(CGFloat)y {
    // Icona dell'app accanto al titolo: la stessa che compare nel Dock.
    NSImageView *iconView = [[NSImageView alloc] initWithFrame:
                             NSMakeRect(XPWinPadding, y, 44, 44)];
    NSString *iconPath = [[NSBundle mainBundle] pathForResource:@"AppIcon" ofType:@"icns"];
    if (iconPath) iconView.image = [[NSImage alloc] initWithContentsOfFile:iconPath];
    iconView.imageScaling = NSImageScaleProportionallyUpOrDown;
    [content addSubview:iconView];

    NSTextField *title = [self labelWithText:@"XAMPP"
                                        font:[NSFont systemFontOfSize:22 weight:NSFontWeightBold]
                                       color:[XPTheme text]
                                       frame:NSMakeRect(XPWinPadding + 56, y + 2, 300, 28)];
    [content addSubview:title];

    // Stessa dicitura del footer della dashboard: la versione di XAMPP letta
    // dall'installazione, poi quella del restyling.
    NSString *appVersion = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    NSString *xamppVersion = [XPPaths xamppVersion];
    NSString *subtitleText = xamppVersion
        ? [NSString stringWithFormat:@"XAMPP %@ · v%@ restyling", xamppVersion, appVersion]
        : [NSString stringWithFormat:@"v%@ restyling", appVersion];

    NSTextField *subtitle = [self labelWithText:subtitleText
                                           font:[XPTheme fontSmall]
                                          color:[XPTheme textMuted]
                                          frame:NSMakeRect(XPWinPadding + 56, y + 28, 340, 16)];
    [content addSubview:subtitle];

    self.statusBadge = [self labelWithText:@""
                                      font:[XPTheme fontBody]
                                     color:[XPTheme textMuted]
                                     frame:NSMakeRect(XPWinWidth - XPWinPadding - 160, y + 12, 160, 20)];
    self.statusBadge.alignment = NSTextAlignmentRight;
    [content addSubview:self.statusBadge];

    return y + 44 + 18;
}

- (CGFloat)addSectionTitle:(NSString *)text to:(NSView *)content atY:(CGFloat)y {
    NSTextField *label = [self labelWithText:[text uppercaseString]
                                        font:[NSFont systemFontOfSize:10 weight:NSFontWeightSemibold]
                                       color:[XPTheme textMuted]
                                       frame:NSMakeRect(XPWinPadding, y, 300, 14)];
    // Un filo di spaziatura fra le lettere rende i titoli di sezione leggibili
    // anche a corpo piccolo.
    label.attributedStringValue = [[NSAttributedString alloc]
        initWithString:[text uppercaseString]
            attributes:@{NSFontAttributeName: [NSFont systemFontOfSize:10 weight:NSFontWeightSemibold],
                         NSForegroundColorAttributeName: [XPTheme textMuted],
                         NSKernAttributeName: @1.2}];
    [content addSubview:label];
    return y + 20;
}

- (CGFloat)addServiceRowsTo:(NSView *)content atY:(CGFloat)y {
    for (XPService *service in [XPServiceMonitor shared].services) {
        XPServiceRowView *row = [[XPServiceRowView alloc] initWithService:service];
        row.frame = NSMakeRect(XPWinPadding - 8, y, XPWinWidth - (XPWinPadding - 8) * 2, XPRowHeight);
        row.onToggle = ^(XPService *s) { [[XPActions shared] toggleService:s]; };
        row.onReload = ^(XPService *s) { [[XPActions shared] reloadService:s]; };
        [content addSubview:row];
        [self.rows addObject:row];
        y += XPRowHeight;
    }
    return y + 14;
}

- (CGFloat)addControlButtonsTo:(NSView *)content atY:(CGFloat)y {
    NSArray *buttons = @[
        @[@"Avvia tutto", @(XPButtonStylePrimary), @"play.fill"],
        @[@"Ferma tutto", @(XPButtonStyleGhost),   @"stop.fill"],
        @[@"Riavvia",     @(XPButtonStyleGhost),   @"arrow.clockwise"],
    ];

    CGFloat gap = 10.0;
    CGFloat width = (XPWinWidth - XPWinPadding * 2 - gap * 2) / 3.0;
    CGFloat x = XPWinPadding;

    for (NSUInteger i = 0; i < buttons.count; i++) {
        NSArray *spec = buttons[i];
        XPButton *button = [XPButton buttonWithTitle:spec[0]
                                               style:[spec[1] integerValue]
                                             onClick:^(XPButton *b) {
            if (i == 0)      [[XPActions shared] startAll];
            else if (i == 1) [[XPActions shared] stopAll];
            else             [[XPActions shared] restartAll];
        }];
        button.symbolName = spec[2];
        button.frame = NSMakeRect(x, y, width, 34);
        [content addSubview:button];

        if (i == 0) self.startAllButton = button;
        if (i == 1) self.stopAllButton = button;
        if (i == 2) self.restartButton = button;

        x += width + gap;
    }
    return y + 34 + 18;
}

- (CGFloat)addShortcutsTo:(NSView *)content atY:(CGFloat)y {
    NSArray *shortcuts = @[
        @[@"Dashboard",  @"safari"],
        @[@"phpMyAdmin", @"cylinder.split.1x2"],
        @[@"Cartella htdocs", @"folder"],
        @[@"Visualizza log",  @"doc.text.magnifyingglass"],
    ];
    return [self addGrid:shortcuts to:content atY:y handler:^(NSUInteger index) {
        switch (index) {
            case 0: [[XPActions shared] openDashboard]; break;
            case 1: [[XPActions shared] openPhpMyAdmin]; break;
            case 2: [[XPActions shared] openHtdocs]; break;
            default: [[XPLogWindowController shared] showWindowAndReload]; break;
        }
    }];
}

- (CGFloat)addToolsTo:(NSView *)content atY:(CGFloat)y {
    NSArray *tools = @[
        @[@"Abilita SSL",    @"lock.fill"],
        @[@"Disabilita SSL", @"lock.open"],
        @[@"Controllo sicurezza", @"checkmark.shield"],
        @[@"Backup",         @"externaldrive.fill"],
    ];
    return [self addGrid:tools to:content atY:y handler:^(NSUInteger index) {
        switch (index) {
            case 0: [[XPActions shared] enableSSL]; break;
            case 1: [[XPActions shared] disableSSL]; break;
            case 2: [[XPActions shared] runSecurityCheck]; break;
            default: [[XPActions shared] runBackup]; break;
        }
    }];
}

/// Griglia di pulsanti a due colonne.
- (CGFloat)addGrid:(NSArray *)items
                to:(NSView *)content
               atY:(CGFloat)y
           handler:(void (^)(NSUInteger index))handler {

    CGFloat gap = 10.0;
    CGFloat width = (XPWinWidth - XPWinPadding * 2 - gap) / 2.0;
    CGFloat height = 32.0;

    for (NSUInteger i = 0; i < items.count; i++) {
        NSArray *spec = items[i];
        XPButton *button = [XPButton buttonWithTitle:spec[0]
                                               style:XPButtonStyleGhost
                                             onClick:^(XPButton *b) { handler(i); }];
        button.symbolName = spec[1];
        button.frame = NSMakeRect(XPWinPadding + (i % 2) * (width + gap),
                                  y + (i / 2) * (height + gap),
                                  width, height);
        [content addSubview:button];
    }

    NSUInteger rows = (items.count + 1) / 2;
    return y + rows * (height + gap) + 8;
}

- (CGFloat)addConfigButtonsTo:(NSView *)content atY:(CGFloat)y {
    NSArray<NSDictionary *> *files = [XPPaths configFiles];
    if (files.count == 0) {
        NSTextField *empty = [self labelWithText:@"Nessun file di configurazione trovato"
                                            font:[XPTheme fontSmall]
                                           color:[XPTheme textMuted]
                                           frame:NSMakeRect(XPWinPadding, y, 400, 16)];
        [content addSubview:empty];
        return y + 26;
    }

    CGFloat gap = 8.0;
    CGFloat width = (XPWinWidth - XPWinPadding * 2 - gap * 2) / 3.0;
    CGFloat height = 28.0;

    for (NSUInteger i = 0; i < files.count; i++) {
        NSString *path = files[i][@"path"];
        XPButton *button = [XPButton buttonWithTitle:files[i][@"title"]
                                               style:XPButtonStyleQuiet
                                             onClick:^(XPButton *b) {
            [[XPActions shared] revealFile:path];
        }];
        button.toolTip = path;
        button.frame = NSMakeRect(XPWinPadding + (i % 3) * (width + gap),
                                  y + (i / 3) * (height + gap),
                                  width, height);
        [content addSubview:button];
    }

    NSUInteger rows = (files.count + 2) / 3;
    y += rows * (height + gap) + 4;

    XPButton *folderButton = [XPButton buttonWithTitle:@"Apri cartella XAMPP"
                                                 style:XPButtonStyleQuiet
                                               onClick:^(XPButton *b) {
        [[XPActions shared] openXamppFolder];
    }];
    folderButton.symbolName = @"folder.badge.gearshape";
    folderButton.frame = NSMakeRect(XPWinPadding, y, 200, 26);
    [content addSubview:folderButton];

    return y + 26 + 14;
}

/// Selettore del tema, gli stessi tre stati del sito.
- (CGFloat)addThemePickerTo:(NSView *)content atY:(CGFloat)y {
    NSSegmentedControl *picker = [NSSegmentedControl
        segmentedControlWithLabels:@[@"Automatico", @"Scuro", @"Chiaro"]
                      trackingMode:NSSegmentSwitchTrackingSelectOne
                            target:self
                            action:@selector(themeChanged:)];
    picker.frame = NSMakeRect(XPWinPadding, y, 260, 26);

    // L'ordine dei segmenti segue quello di XPThemePreference.
    picker.selectedSegment = [XPTheme preference];
    [content addSubview:picker];

    NSTextField *hint = [self labelWithText:@"Automatico segue l'impostazione di macOS"
                                       font:[XPTheme fontSmall]
                                      color:[XPTheme textMuted]
                                      frame:NSMakeRect(XPWinPadding + 272, y + 5, 260, 16)];
    [content addSubview:hint];

    return y + 26 + 16;
}

- (void)themeChanged:(NSSegmentedControl *)sender {
    [XPTheme setPreference:(XPThemePreference)sender.selectedSegment];
}

- (CGFloat)addMessageBarTo:(NSView *)content atY:(CGFloat)y {
    // Separatore sopra la barra dei messaggi.
    NSBox *line = [[NSBox alloc] initWithFrame:NSMakeRect(0, y, XPWinWidth, 1)];
    line.boxType = NSBoxCustom;
    line.borderWidth = 0;
    line.fillColor = [XPTheme border];
    [content addSubview:line];

    y += 10;
    self.messageLabel = [self labelWithText:@""
                                       font:[XPTheme fontSmall]
                                      color:[XPTheme textMuted]
                                      frame:NSMakeRect(XPWinPadding, y, XPWinWidth - XPWinPadding * 2, 16)];
    self.messageLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [content addSubview:self.messageLabel];

    return y + 16 + XPWinPadding;
}

#pragma mark - Fabbriche

- (NSTextField *)labelWithText:(NSString *)text
                          font:(NSFont *)font
                         color:(NSColor *)color
                         frame:(NSRect)frame {
    NSTextField *label = [[NSTextField alloc] initWithFrame:frame];
    label.stringValue = text ?: @"";
    label.editable = NO;
    label.selectable = NO;
    label.bordered = NO;
    label.drawsBackground = NO;
    label.font = font;
    label.textColor = color;
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
    if (busy)                    { text = @"operazione in corso"; color = [XPTheme amber]; }
    else if (monitor.allRunning) { text = @"tutti i servizi attivi"; color = [XPTheme running]; }
    else if (monitor.anyRunning) { text = @"attivo solo in parte"; color = [XPTheme amber]; }
    else                         { text = @"tutti i servizi fermi"; color = [XPTheme textMuted]; }

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
