//
//  XPVHostRowView.m
//

#import "XPVHostRowView.h"
#import "XPTheme.h"
#import "XPButton.h"
#import "XPActions.h"
#import "XPLayout.h"
#import "XPGitInfo.h"

@interface XPVHostRowView ()
@property (nonatomic, strong, readwrite) XPVirtualHost *host;
@property (nonatomic, strong) XPButton *openButton;
@property (nonatomic, strong) XPButton *folderButton;
@property (nonatomic, strong) XPButton *repoButton;
@end


@implementation XPVHostRowView

- (instancetype)initWithHost:(XPVirtualHost *)host {
    if ((self = [super initWithFrame:NSMakeRect(0, 0, 500, 34)])) {
        _host = host;
        self.wantsLayer = YES;
        self.toolTip = [NSString stringWithFormat:@"%@\n%@",
                        host.documentRoot, [host stateDescription]];
        [self buildButtons];
    }
    return self;
}

- (void)buildButtons {
    // Un virtual host commentato non ha nulla da aprire: al posto dei pulsanti
    // resta la spiegazione del perché quella porta è chiusa.
    if (self.host.state == XPVHostStateDisabled) return;

    XPVirtualHost *host = self.host;

    self.openButton = [XPButton buttonWithTitle:NSLocalizedString(@"btn.open", nil) style:XPButtonStyleGhost onClick:^(XPButton *b) {
        [[XPActions shared] openVirtualHost:host];
    }];
    [self addSubview:self.openButton];

    self.folderButton = [XPButton buttonWithTitle:NSLocalizedString(@"btn.folder", nil) style:XPButtonStyleQuiet onClick:^(XPButton *b) {
        [[XPActions shared] revealFile:host.documentRoot];
    }];
    [self addSubview:self.folderButton];

    // Il repository, se c'è: cliccandolo si apre su GitHub.
    if (host.git.webURL) {
        XPGitInfo *git = host.git;
        self.repoButton = [XPButton buttonWithTitle:git.shortName
                                               style:XPButtonStyleQuiet
                                             onClick:^(XPButton *b) {
            [[NSWorkspace sharedWorkspace] openURL:git.webURL];
        }];
        self.repoButton.symbolName = git.isGitHub ? @"chevron.left.forwardslash.chevron.right"
                                                  : @"arrow.triangle.branch";
        self.repoButton.toolTip = git.branch
            ? [NSString stringWithFormat:@"%@ · %@\n%@", git.shortName, git.branch,
               git.webURL.absoluteString]
            : git.webURL.absoluteString;
        [self addSubview:self.repoButton];
    }
}

- (void)layout {
    [super layout];
    if (!self.openButton) return;   // riga di un host disattivato

    CGFloat y = NSMidY(self.bounds) - 12;
    CGFloat width = NSWidth(self.bounds);
    CGFloat right = width - 10;

    // In urdu i pulsanti passano sul lato opposto, come il resto della riga.
    self.folderButton.frame = XPMirror(NSMakeRect(right - 74, y, 74, 24), width);
    self.openButton.frame   = XPMirror(NSMakeRect(right - 74 - 4 - 58, y, 58, 24), width);

    if (self.repoButton) {
        CGFloat repoWidth = MIN(190, MAX(120, width - 470));
        self.repoButton.frame = XPMirror(NSMakeRect(right - 74 - 4 - 58 - 6 - repoWidth,
                                                    y, repoWidth, 24), width);
    }
}

- (void)drawRect:(NSRect)dirtyRect {
    BOOL listening = (self.host.state == XPVHostStateListening);
    BOOL disabled  = (self.host.state == XPVHostStateDisabled);

    // Indicatore: pieno se risponde, contorno se no. La forma distingue gli
    // stati anche senza percezione del colore.
    CGFloat width = NSWidth(self.bounds);
    NSRect dot = XPMirror(NSMakeRect(10, NSMidY(self.bounds) - 3.5, 7, 7), width);
    NSBezierPath *dotPath = [NSBezierPath bezierPathWithOvalInRect:dot];
    if (listening) {
        [[XPTheme running] setFill];
        [dotPath fill];
    } else {
        [(disabled ? [XPTheme textMuted] : [XPTheme amber]) setStroke];
        dotPath.lineWidth = 1.5;
        [dotPath stroke];
    }

    // Porta, in monospaziato perché le cifre restino incolonnate.
    NSDictionary *portAttrs = @{
        NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:11
                                                              weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: listening ? [XPTheme accent] : [XPTheme textMuted]
    };
    NSString *port = [NSString stringWithFormat:@"%ld", (long)self.host.port];
    NSMutableDictionary *portDraw = [portAttrs mutableCopy];
    portDraw[NSParagraphStyleAttributeName] = XPNaturalParagraphStyle(NSLineBreakByClipping);
    [port drawInRect:XPMirror(NSMakeRect(26, NSMidY(self.bounds) - 7, 40, 14), width)
      withAttributes:portDraw];

    // Nome del progetto, troncato se non ci sta.
    CGFloat nameX = 70;
    CGFloat available = NSWidth(self.bounds) - nameX - (disabled ? 200 : 150)
                        - (self.repoButton ? NSWidth(self.repoButton.frame) + 6 : 0);

    NSDictionary *nameAttrs = @{
        NSFontAttributeName: [XPTheme fontBody],
        NSForegroundColorAttributeName: disabled ? [XPTheme textMuted] : [XPTheme text],
        NSParagraphStyleAttributeName: XPNaturalParagraphStyle(NSLineBreakByTruncatingMiddle)
    };
    [self.host.name drawInRect:XPMirror(NSMakeRect(nameX, NSMidY(self.bounds) - 8,
                                                   available, 16), width)
                withAttributes:nameAttrs];

    if (disabled) {
        // Allineato al bordo finale, qualunque sia la direzione.
        NSMutableParagraphStyle *stateStyle =
            [XPNaturalParagraphStyle(NSLineBreakByTruncatingTail) mutableCopy];
        stateStyle.alignment = XPIsRTL() ? NSTextAlignmentLeft : NSTextAlignmentRight;

        NSDictionary *stateAttrs = @{
            NSFontAttributeName: [XPTheme fontSmall],
            NSForegroundColorAttributeName: [XPTheme textMuted],
            NSParagraphStyleAttributeName: stateStyle
        };
        [NSLocalizedString(@"vhost.disabled", nil)
            drawInRect:XPMirror(NSMakeRect(width - 210, NSMidY(self.bounds) - 7, 200, 14), width)
        withAttributes:stateAttrs];
    }
}

@end
