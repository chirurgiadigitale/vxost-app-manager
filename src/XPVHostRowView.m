//
//  XPVHostRowView.m
//

#import "XPVHostRowView.h"
#import "XPTheme.h"
#import "XPButton.h"
#import "XPActions.h"

@interface XPVHostRowView ()
@property (nonatomic, strong, readwrite) XPVirtualHost *host;
@property (nonatomic, strong) XPButton *openButton;
@property (nonatomic, strong) XPButton *folderButton;
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

    self.openButton = [XPButton buttonWithTitle:@"Apri" style:XPButtonStyleGhost onClick:^(XPButton *b) {
        [[XPActions shared] openVirtualHost:host];
    }];
    [self addSubview:self.openButton];

    self.folderButton = [XPButton buttonWithTitle:@"Cartella" style:XPButtonStyleQuiet onClick:^(XPButton *b) {
        [[XPActions shared] revealFile:host.documentRoot];
    }];
    [self addSubview:self.folderButton];
}

- (void)layout {
    [super layout];
    if (!self.openButton) return;   // riga di un host disattivato

    CGFloat y = NSMidY(self.bounds) - 12;
    CGFloat right = NSWidth(self.bounds) - 10;

    self.folderButton.frame = NSMakeRect(right - 74, y, 74, 24);
    self.openButton.frame   = NSMakeRect(right - 74 - 4 - 58, y, 58, 24);
}

- (void)drawRect:(NSRect)dirtyRect {
    BOOL listening = (self.host.state == XPVHostStateListening);
    BOOL disabled  = (self.host.state == XPVHostStateDisabled);

    // Indicatore: pieno se risponde, contorno se no. La forma distingue gli
    // stati anche senza percezione del colore.
    NSRect dot = NSMakeRect(10, NSMidY(self.bounds) - 3.5, 7, 7);
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
    [port drawAtPoint:NSMakePoint(26, NSMidY(self.bounds) - 7) withAttributes:portAttrs];

    // Nome del progetto, troncato se non ci sta.
    CGFloat nameX = 70;
    CGFloat available = NSWidth(self.bounds) - nameX - (disabled ? 200 : 150);

    NSMutableParagraphStyle *paragraph = [[NSMutableParagraphStyle alloc] init];
    paragraph.lineBreakMode = NSLineBreakByTruncatingMiddle;

    NSDictionary *nameAttrs = @{
        NSFontAttributeName: [XPTheme fontBody],
        NSForegroundColorAttributeName: disabled ? [XPTheme textMuted] : [XPTheme text],
        NSParagraphStyleAttributeName: paragraph
    };
    [self.host.name drawInRect:NSMakeRect(nameX, NSMidY(self.bounds) - 8, available, 16)
                withAttributes:nameAttrs];

    if (disabled) {
        NSDictionary *stateAttrs = @{
            NSFontAttributeName: [XPTheme fontSmall],
            NSForegroundColorAttributeName: [XPTheme textMuted],
            NSParagraphStyleAttributeName: ({
                NSMutableParagraphStyle *p = [[NSMutableParagraphStyle alloc] init];
                p.alignment = NSTextAlignmentRight;
                p;
            })
        };
        [@"disattivato nella configurazione"
            drawInRect:NSMakeRect(NSWidth(self.bounds) - 210, NSMidY(self.bounds) - 7, 200, 14)
        withAttributes:stateAttrs];
    }
}

@end
