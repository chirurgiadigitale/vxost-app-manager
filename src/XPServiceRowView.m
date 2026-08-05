//
//  XPServiceRowView.m
//

#import "XPServiceRowView.h"
#import "XPTheme.h"
#import "XPButton.h"

static const CGFloat XPRowHeight = 52.0;

@interface XPServiceRowView ()
@property (nonatomic, strong, readwrite) XPService *service;
@property (nonatomic, strong) XPButton *toggleButton;
@property (nonatomic, strong) NSProgressIndicator *spinner;
@end


@implementation XPServiceRowView

- (instancetype)initWithService:(XPService *)service {
    if ((self = [super initWithFrame:NSMakeRect(0, 0, 300, XPRowHeight)])) {
        _service = service;
        self.wantsLayer = YES;

        _toggleButton = [XPButton buttonWithTitle:@"Avvia" style:XPButtonStyleGhost onClick:^(XPButton *b) {
            if (self.onToggle) self.onToggle(self.service);
        }];
        [self addSubview:_toggleButton];

        // Indicatore di transizione, mostrato al posto del pulsante quando il
        // comando privilegiato è in esecuzione.
        _spinner = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(0, 0, 16, 16)];
        _spinner.style = NSProgressIndicatorStyleSpinning;
        _spinner.controlSize = NSControlSizeSmall;
        _spinner.displayedWhenStopped = NO;
        [self addSubview:_spinner];

        [self refresh];
    }
    return self;
}

- (void)layout {
    [super layout];
    CGFloat buttonWidth = 66.0;
    self.toggleButton.frame = NSMakeRect(NSWidth(self.bounds) - buttonWidth - 14,
                                         NSMidY(self.bounds) - 13,
                                         buttonWidth, 26);
    self.spinner.frame = NSMakeRect(NSWidth(self.bounds) - 14 - buttonWidth / 2 - 8,
                                    NSMidY(self.bounds) - 8, 16, 16);
}

#pragma mark - Aggiornamento

- (void)refresh {
    switch (self.service.state) {
        case XPServiceStateRunning:
            self.toggleButton.title = @"Ferma";
            self.toggleButton.style = XPButtonStyleDanger;
            self.toggleButton.hidden = NO;
            self.toggleButton.enabled = YES;
            [self.spinner stopAnimation:nil];
            break;
        case XPServiceStateStopped:
            self.toggleButton.title = @"Avvia";
            self.toggleButton.style = XPButtonStyleGhost;
            self.toggleButton.hidden = NO;
            self.toggleButton.enabled = YES;
            [self.spinner stopAnimation:nil];
            break;
        case XPServiceStateBusy:
            self.toggleButton.hidden = YES;
            [self.spinner startAnimation:nil];
            break;
    }
    // L'elenco delle porte è troncato nella riga: per intero sta nel tooltip.
    self.toolTip = [self.service allPortsDescription];
    [self setNeedsDisplay:YES];
}

#pragma mark - Menu contestuale

- (NSMenu *)menuForEvent:(NSEvent *)event {
    NSMenu *menu = [[NSMenu alloc] init];
    NSMenuItem *reload = [[NSMenuItem alloc] initWithTitle:
                          [NSString stringWithFormat:@"Ricarica %@", self.service.name]
                                                    action:@selector(reloadFromMenu:)
                                             keyEquivalent:@""];
    reload.target = self;
    reload.enabled = (self.service.state == XPServiceStateRunning);
    [menu addItem:reload];
    return menu;
}

- (void)reloadFromMenu:(id)sender {
    if (self.onReload) self.onReload(self.service);
}

#pragma mark - Disegno

- (void)drawRect:(NSRect)dirtyRect {
    // Sfondo della riga
    NSRect card = NSInsetRect(self.bounds, 8, 3);
    NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:card
                                                      xRadius:[XPTheme radiusMedium]
                                                      yRadius:[XPTheme radiusMedium]];
    [[XPTheme surface] setFill];
    [bg fill];
    [[XPTheme border] setStroke];
    bg.lineWidth = 1.0;
    [bg stroke];

    BOOL running = (self.service.state == XPServiceStateRunning);

    // Indicatore di stato: cerchio pieno se attivo, anello vuoto se fermo.
    // La differenza di forma, non solo di colore, lo rende leggibile anche
    // a chi non distingue verde e grigio.
    NSRect dot = NSMakeRect(NSMinX(card) + 14, NSMidY(card) - 4, 8, 8);
    NSBezierPath *dotPath = [NSBezierPath bezierPathWithOvalInRect:dot];
    if (running) {
        [[XPTheme running] setFill];
        [dotPath fill];
        // Alone tenue attorno al punto attivo.
        NSBezierPath *halo = [NSBezierPath bezierPathWithOvalInRect:NSInsetRect(dot, -3.5, -3.5)];
        [[[XPTheme running] colorWithAlphaComponent:0.22] setStroke];
        halo.lineWidth = 2.0;
        [halo stroke];
    } else {
        [[XPTheme textMuted] setStroke];
        dotPath.lineWidth = 1.5;
        [dotPath stroke];
    }

    // Nome del servizio
    NSDictionary *nameAttrs = @{
        NSFontAttributeName: [XPTheme fontTitle],
        NSForegroundColorAttributeName: running ? [XPTheme text] : [XPTheme textSoft]
    };
    [self.service.name drawAtPoint:NSMakePoint(NSMinX(card) + 32, NSMidY(card) + 1)
                    withAttributes:nameAttrs];

    // Sottotitolo: porte e PID
    NSString *detail;
    if (self.service.state == XPServiceStateBusy) {
        detail = @"attendere…";
    } else if (running) {
        detail = [NSString stringWithFormat:@"porta %@ · pid %d",
                  [self.service portsDescription], self.service.pid];
    } else {
        detail = [NSString stringWithFormat:@"fermo · porta %@", [self.service portsDescription]];
    }

    NSDictionary *detailAttrs = @{
        NSFontAttributeName: [XPTheme fontSmall],
        NSForegroundColorAttributeName: [XPTheme textMuted]
    };
    [detail drawAtPoint:NSMakePoint(NSMinX(card) + 32, NSMidY(card) - 14)
         withAttributes:detailAttrs];

    // Barretta colorata a sinistra, nel colore semantico del servizio.
    NSRect accent = NSMakeRect(NSMinX(card) + 1, NSMidY(card) - 10, 3, 20);
    NSBezierPath *accentPath = [NSBezierPath bezierPathWithRoundedRect:accent xRadius:1.5 yRadius:1.5];
    [[self.service.tint colorWithAlphaComponent:running ? 1.0 : 0.35] setFill];
    [accentPath fill];
}

@end
