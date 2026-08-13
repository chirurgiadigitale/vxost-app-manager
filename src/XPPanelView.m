//
//  XPPanelView.m
//

#import "XPPanelView.h"
#import "XPTheme.h"
#import "XPButton.h"
#import "XPServiceRowView.h"
#import "XPServiceMonitor.h"
#import "XPPaths.h"
#import "XPLayout.h"

static const CGFloat XPPanelWidth   = 320.0;
static const CGFloat XPPanelPadding = 8.0;
static const CGFloat XPRowH         = 52.0;

@interface XPPanelView ()
@property (nonatomic, strong) NSArray<XPService *> *services;
@property (nonatomic, strong) NSMutableArray<XPServiceRowView *> *rows;
@property (nonatomic, strong) XPButton *startAllButton;
@property (nonatomic, strong) XPButton *stopAllButton;
@property (nonatomic, strong) XPButton *restartButton;
@property (nonatomic, strong) NSTextField *messageLabel;
@property (nonatomic, strong) NSTimer *messageTimer;
@property (nonatomic, assign) CGFloat requiredHeight;
@end


@implementation XPPanelView

- (instancetype)initWithServices:(NSArray<XPService *> *)services {
    if ((self = [super initWithFrame:NSMakeRect(0, 0, XPPanelWidth, 420)])) {
        _services = services;
        _rows = [NSMutableArray array];
        self.wantsLayer = YES;
        [self buildInterface];
    }
    return self;
}

// Layout dall'alto verso il basso: più naturale da leggere nel codice.
- (BOOL)isFlipped { return YES; }

#pragma mark - Costruzione

- (void)buildInterface {
    CGFloat y = 54.0;   // sotto l'intestazione, disegnata in drawRect

    // Righe dei servizi
    for (XPService *service in self.services) {
        XPServiceRowView *row = [[XPServiceRowView alloc] initWithService:service];
        row.frame = NSMakeRect(XPPanelPadding, y, XPPanelWidth - XPPanelPadding * 2, XPRowH);   // simmetrico: il contenuto si specchia da sé
        row.onToggle = ^(XPService *s) { [self.delegate panelDidToggleService:s]; };
        row.onReload = ^(XPService *s) { [self.delegate panelDidRequestReload:s]; };
        [self addSubview:row];
        [self.rows addObject:row];
        y += XPRowH;
    }

    y += 10;

    // Azioni globali: tre pulsanti affiancati
    CGFloat gap = 8.0;
    CGFloat available = XPPanelWidth - XPPanelPadding * 2 - 12 - gap * 2;
    CGFloat buttonWidth = available / 3.0;
    CGFloat x = XPPanelPadding + 6;

    self.startAllButton = [XPButton buttonWithTitle:NSLocalizedString(@"btn.startAll", nil) style:XPButtonStylePrimary onClick:^(XPButton *b) {
        [self.delegate panelDidRequestStartAll];
    }];
    self.startAllButton.frame = XPMirror(NSMakeRect(x, y, buttonWidth, 30), XPPanelWidth);
    [self addSubview:self.startAllButton];
    x += buttonWidth + gap;

    self.stopAllButton = [XPButton buttonWithTitle:NSLocalizedString(@"btn.stopAll", nil) style:XPButtonStyleGhost onClick:^(XPButton *b) {
        [self.delegate panelDidRequestStopAll];
    }];
    self.stopAllButton.frame = XPMirror(NSMakeRect(x, y, buttonWidth, 30), XPPanelWidth);
    [self addSubview:self.stopAllButton];
    x += buttonWidth + gap;

    self.restartButton = [XPButton buttonWithTitle:NSLocalizedString(@"btn.restart", nil) style:XPButtonStyleGhost onClick:^(XPButton *b) {
        [self.delegate panelDidRequestRestart];
    }];
    self.restartButton.frame = XPMirror(NSMakeRect(x, y, buttonWidth, 30), XPPanelWidth);
    [self addSubview:self.restartButton];

    y += 30 + 16;

    // Scorciatoie, due per riga
    NSArray *shortcuts = @[
        @{@"title": NSLocalizedString(@"link.dashboard", nil), @"symbol": @"safari", @"sel": @"openDashboard"},
        @{@"title": @"phpMyAdmin", @"symbol": @"cylinder.split.1x2", @"sel": @"openPhpMyAdmin"},
        @{@"title": @"htdocs", @"symbol": @"folder", @"sel": @"openHtdocs"},
        @{@"title": NSLocalizedString(@"link.viewLogs", nil), @"symbol": @"doc.text.magnifyingglass", @"sel": @"openLogs"},
    ];

    CGFloat shortcutWidth = (XPPanelWidth - XPPanelPadding * 2 - 12 - gap) / 2.0;
    for (NSUInteger i = 0; i < shortcuts.count; i++) {
        NSDictionary *item = shortcuts[i];
        NSString *selectorName = item[@"sel"];

        XPButton *button = [XPButton buttonWithTitle:item[@"title"] style:XPButtonStyleGhost onClick:^(XPButton *b) {
            if ([selectorName isEqualToString:@"openDashboard"])  [self.delegate panelDidRequestOpenDashboard];
            else if ([selectorName isEqualToString:@"openPhpMyAdmin"]) [self.delegate panelDidRequestOpenPhpMyAdmin];
            else if ([selectorName isEqualToString:@"openHtdocs"]) [self.delegate panelDidRequestOpenHtdocs];
            else [self.delegate panelDidRequestOpenLogs];
        }];
        button.symbolName = item[@"symbol"];

        CGFloat col = (i % 2) * (shortcutWidth + gap);
        CGFloat rowY = y + (i / 2) * (28 + gap);
        button.frame = XPMirror(NSMakeRect(XPPanelPadding + 6 + col, rowY, shortcutWidth, 28), XPPanelWidth);
        [self addSubview:button];
    }

    y += (28 + gap) * 2 + 6;

    // Riga di messaggio (esiti e errori)
    self.messageLabel = [[NSTextField alloc] initWithFrame:
                         NSMakeRect(XPPanelPadding + 6, y, XPPanelWidth - XPPanelPadding * 2 - 12, 16)];
    self.messageLabel.editable = NO;
    self.messageLabel.bordered = NO;
    self.messageLabel.drawsBackground = NO;
    self.messageLabel.font = [XPTheme fontSmall];
    self.messageLabel.textColor = [XPTheme textMuted];
    self.messageLabel.stringValue = @"";
    self.messageLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.messageLabel.alignment = NSTextAlignmentNatural;
    [self addSubview:self.messageLabel];

    y += 20;

    // Footer: finestra completa, menu "Altro" e uscita
    XPButton *windowButton = [XPButton buttonWithTitle:NSLocalizedString(@"btn.window", nil) style:XPButtonStyleQuiet onClick:^(XPButton *b) {
        [self.delegate panelDidRequestOpenMainWindow];
    }];
    windowButton.symbolName = @"macwindow";
    windowButton.frame = XPMirror(NSMakeRect(XPPanelPadding + 6, y, 92, 24), XPPanelWidth);
    [self addSubview:windowButton];

    XPButton *moreButton = [XPButton buttonWithTitle:NSLocalizedString(@"btn.more", nil) style:XPButtonStyleQuiet onClick:^(XPButton *b) {
        [self showMoreMenuFromButton:b];
    }];
    moreButton.frame = XPMirror(NSMakeRect(XPPanelPadding + 6 + 96, y, 70, 24), XPPanelWidth);
    [self addSubview:moreButton];

    XPButton *quitButton = [XPButton buttonWithTitle:NSLocalizedString(@"btn.quit", nil) style:XPButtonStyleQuiet onClick:^(XPButton *b) {
        [self.delegate panelDidRequestQuit];
    }];
    quitButton.frame = XPMirror(NSMakeRect(XPPanelWidth - XPPanelPadding - 6 - 60, y, 60, 24), XPPanelWidth);
    [self addSubview:quitButton];

    y += 24 + XPPanelPadding;

    self.requiredHeight = y;
    self.frame = NSMakeRect(0, 0, XPPanelWidth, y);
}

#pragma mark - Menu "Altro"

- (void)showMoreMenuFromButton:(XPButton *)button {
    NSMenu *menu = [[NSMenu alloc] init];

    [menu addItemWithTitle:NSLocalizedString(@"tool.enableSSL", nil) action:@selector(enableSSL:) keyEquivalent:@""].target = self;
    [menu addItemWithTitle:NSLocalizedString(@"tool.disableSSL", nil) action:@selector(disableSSL:) keyEquivalent:@""].target = self;
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:NSLocalizedString(@"tool.security", nil) action:@selector(securityCheck:) keyEquivalent:@""].target = self;
    [menu addItemWithTitle:NSLocalizedString(@"tool.backup", nil) action:@selector(backup:) keyEquivalent:@""].target = self;
    [menu addItem:[NSMenuItem separatorItem]];

    // Sottomenu con i file di configurazione presenti
    NSMenuItem *configItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"config.files", nil) action:nil keyEquivalent:@""];
    NSMenu *configMenu = [[NSMenu alloc] init];
    for (NSDictionary *cfg in [XPPaths configFiles]) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:cfg[@"title"]
                                                      action:@selector(openConfigFile:)
                                               keyEquivalent:@""];
        item.target = self;
        item.representedObject = cfg[@"path"];
        [configMenu addItem:item];
    }
    configItem.submenu = configMenu;
    [menu addItem:configItem];

    [menu addItemWithTitle:NSLocalizedString(@"link.vxostFolder", nil) action:@selector(openVxostFolder:) keyEquivalent:@""].target = self;

    NSPoint point = NSMakePoint(0, NSHeight(button.bounds) + 4);
    [menu popUpMenuPositioningItem:nil atLocation:point inView:button];
}

- (void)enableSSL:(id)sender {
    [self.delegate panelDidRequestVxostAction:@"enablessl"
                               confirmMessage:nil];
}

- (void)disableSSL:(id)sender {
    [self.delegate panelDidRequestVxostAction:@"disablessl"
                               confirmMessage:nil];
}

- (void)securityCheck:(id)sender {
    [self.delegate panelDidRequestVxostAction:@"security" confirmMessage:nil];
}

- (void)backup:(id)sender {
    [self.delegate panelDidRequestVxostAction:@"backup"
                               confirmMessage:nil];
}

- (void)openConfigFile:(NSMenuItem *)sender {
    [self.delegate panelDidRequestOpenFile:sender.representedObject];
}

- (void)openVxostFolder:(id)sender {
    [self.delegate panelDidRequestOpenFile:[XPPaths installRoot]];
}

#pragma mark - Aggiornamento

- (void)refresh {
    for (XPServiceRowView *row in self.rows) [row refresh];

    XPServiceMonitor *monitor = [XPServiceMonitor shared];
    BOOL busy = monitor.anyBusy;

    self.startAllButton.enabled = !busy && !monitor.allRunning;
    self.stopAllButton.enabled  = !busy && monitor.anyRunning;
    self.restartButton.enabled  = !busy && monitor.anyRunning;

    [self setNeedsDisplay:YES];
}

- (void)showMessage:(NSString *)message isError:(BOOL)isError {
    self.messageLabel.stringValue = message ?: @"";
    self.messageLabel.textColor = isError ? [XPTheme danger] : [XPTheme textMuted];

    [self.messageTimer invalidate];
    if (message.length > 0) {
        // I messaggi si cancellano da soli: il pannello resta pulito.
        self.messageTimer = [NSTimer scheduledTimerWithTimeInterval:(isError ? 10.0 : 5.0)
                                                            repeats:NO
                                                              block:^(NSTimer *t) {
            self.messageLabel.stringValue = @"";
        }];
    }
}

#pragma mark - Disegno

- (void)drawRect:(NSRect)dirtyRect {
    // Fondo del pannello
    [[XPTheme bgElev] setFill];
    NSRectFill(self.bounds);

    // Intestazione
    NSRect header = NSMakeRect(0, 0, NSWidth(self.bounds), 46);

    NSDictionary *titleAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:15 weight:NSFontWeightBold],
        NSForegroundColorAttributeName: [XPTheme text]
    };
    NSMutableDictionary *titleDraw = [titleAttrs mutableCopy];
    titleDraw[NSParagraphStyleAttributeName] = XPNaturalParagraphStyle(NSLineBreakByClipping);
    [@"VXOST" drawInRect:XPMirror(NSMakeRect(20, 13, 160, 22), NSWidth(self.bounds))
          withAttributes:titleDraw];

    // Badge di stato complessivo, allineato a destra
    XPServiceMonitor *monitor = [XPServiceMonitor shared];
    NSString *badgeText;
    NSColor *badgeColor;
    if (monitor.anyBusy)         { badgeText = NSLocalizedString(@"badge.busy", nil); badgeColor = [XPTheme amber]; }
    else if (monitor.allRunning) { badgeText = NSLocalizedString(@"badge.allRunning", nil); badgeColor = [XPTheme running]; }
    else if (monitor.anyRunning) { badgeText = NSLocalizedString(@"badge.partial", nil); badgeColor = [XPTheme amber]; }
    else                         { badgeText = NSLocalizedString(@"badge.stopped", nil); badgeColor = [XPTheme textMuted]; }

    NSDictionary *badgeAttrs = @{
        NSFontAttributeName: [XPTheme fontSmall],
        NSForegroundColorAttributeName: badgeColor
    };
    NSSize badgeSize = [badgeText sizeWithAttributes:badgeAttrs];
    NSRect badgeRect = XPMirror(NSMakeRect(NSWidth(self.bounds) - badgeSize.width - 30,
                                           15, badgeSize.width + 16, 18), NSWidth(self.bounds));
    NSBezierPath *badge = [NSBezierPath bezierPathWithRoundedRect:badgeRect xRadius:9 yRadius:9];
    [[badgeColor colorWithAlphaComponent:0.14] setFill];
    [badge fill];
    [badgeText drawAtPoint:NSMakePoint(NSMinX(badgeRect) + 8, NSMinY(badgeRect) + 3)
            withAttributes:badgeAttrs];

    // Linea di separazione sotto l'intestazione
    [[XPTheme border] setFill];
    NSRectFill(NSMakeRect(0, NSMaxY(header) - 1, NSWidth(self.bounds), 1));
}

@end
