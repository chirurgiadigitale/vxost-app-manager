//
//  XPButton.m
//

#import "XPButton.h"
#import "XPTheme.h"
#import "XPLayout.h"

@interface XPButton ()
@property (nonatomic, assign) BOOL hovered;
@property (nonatomic, assign) BOOL pressed;
@property (nonatomic, strong) NSTrackingArea *tracking;
@end


@implementation XPButton

+ (instancetype)buttonWithTitle:(NSString *)title
                          style:(XPButtonStyle)style
                        onClick:(void (^)(XPButton *))onClick {
    XPButton *button = [[XPButton alloc] initWithFrame:NSMakeRect(0, 0, 100, 28)];
    button.title   = title;
    button.style   = style;
    button.onClick = onClick;
    return button;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _enabled = YES;
        self.wantsLayer = YES;
    }
    return self;
}

#pragma mark - Proprietà che richiedono ridisegno

- (void)setTitle:(NSString *)title       { _title = [title copy];       [self setNeedsDisplay:YES]; }
- (void)setSymbolName:(NSString *)name   { _symbolName = [name copy];   [self setNeedsDisplay:YES]; }
- (void)setStyle:(XPButtonStyle)style    { _style = style;              [self setNeedsDisplay:YES]; }
- (void)setEnabled:(BOOL)enabled         { _enabled = enabled;          [self setNeedsDisplay:YES]; }

#pragma mark - Hover

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (self.tracking) [self removeTrackingArea:self.tracking];
    self.tracking = [[NSTrackingArea alloc] initWithRect:self.bounds
                                                 options:(NSTrackingMouseEnteredAndExited |
                                                          NSTrackingActiveInActiveApp)
                                                   owner:self
                                                userInfo:nil];
    [self addTrackingArea:self.tracking];
}

- (void)mouseEntered:(NSEvent *)event {
    if (!self.enabled) return;
    self.hovered = YES;
    [self setNeedsDisplay:YES];
    [[NSCursor pointingHandCursor] set];
}

- (void)mouseExited:(NSEvent *)event {
    self.hovered = NO;
    [self setNeedsDisplay:YES];
    [[NSCursor arrowCursor] set];
}

#pragma mark - Click

- (void)mouseDown:(NSEvent *)event {
    if (!self.enabled) return;
    self.pressed = YES;
    [self setNeedsDisplay:YES];
}

- (void)mouseUp:(NSEvent *)event {
    if (!self.enabled) return;
    self.pressed = NO;
    [self setNeedsDisplay:YES];

    // Scatta solo se il rilascio avviene dentro il pulsante, come da convenzione.
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    if (NSPointInRect(point, self.bounds) && self.onClick) {
        self.onClick(self);
    }
}

#pragma mark - Disegno

- (void)drawRect:(NSRect)dirtyRect {
    NSRect rect = NSInsetRect(self.bounds, 0.5, 0.5);
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:rect
                                                        xRadius:[XPTheme radiusSmall]
                                                        yRadius:[XPTheme radiusSmall]];

    NSColor *fill = nil, *stroke = nil, *label = nil;
    // Lo smorzamento vale per il fondo, non per la scritta. Applicandolo a
    // entrambi il contrasto fra i due crolla: sul pulsante principale il nero
    // al 35% su magenta al 35% arriva a 1.30:1, e l'etichetta sparisce.
    // "Avvia tutto" era illeggibile ogni volta che i servizi erano gia' su,
    // cioe' quasi sempre.
    CGFloat alpha = self.enabled ? 1.0 : 0.35;
    CGFloat labelAlpha = alpha;

    switch (self.style) {
        case XPButtonStylePrimary:
            // Da disabilitato la scritta resta piena e cambia colore: il fondo
            // smorzato diventa viola scuro sul tema scuro (bianco: 11.24:1) e
            // lilla chiaro su quello chiaro (nero: 9.58:1). Un colore solo per
            // entrambi non esiste.
            if (!self.enabled) {
                labelAlpha = 1.0;
            }
            // Tinta unita, non il gradiente: sopra il gradiente nessun colore di
            // testo regge per tutta la scala. Il nero sparisce sul blu iniziale
            // (1.87:1), il bianco sull'arancione finale (2.51:1). Il pulsante di
            // download sul sito e' pieno per la stessa ragione.
            fill   = [XPTheme accent];
            stroke = nil;
            label  = self.enabled ? [XPTheme accentInk] : [XPTheme accentInkDimmed];
            break;
        case XPButtonStyleGhost:
            fill   = self.hovered ? [XPTheme surface2] : [XPTheme surface];
            stroke = self.hovered ? [XPTheme borderStrong] : [XPTheme border];
            label  = [XPTheme text];
            break;
        case XPButtonStyleDanger:
            fill   = self.hovered ? [[XPTheme danger] colorWithAlphaComponent:0.14] : [XPTheme surface];
            stroke = [[XPTheme danger] colorWithAlphaComponent:self.hovered ? 0.7 : 0.4];
            label  = [XPTheme danger];
            break;
        case XPButtonStyleQuiet:
            fill   = self.hovered ? [XPTheme surface] : [NSColor clearColor];
            stroke = nil;
            label  = self.hovered ? [XPTheme text] : [XPTheme textSoft];
            break;
    }

    // Il click scurisce leggermente, per dare un riscontro immediato.
    if (self.pressed && self.enabled) {
        fill = [fill blendedColorWithFraction:0.18 ofColor:[NSColor blackColor]] ?: fill;
    }

    if (fill && fill != [NSColor clearColor]) {
        [[fill colorWithAlphaComponent:CGColorGetAlpha(fill.CGColor) * alpha] setFill];
        [path fill];
    }
    if (stroke) {
        [[stroke colorWithAlphaComponent:CGColorGetAlpha(stroke.CGColor) * alpha] setStroke];
        path.lineWidth = 1.0;
        [path stroke];
    }

    // Contenuto: simbolo opzionale + testo, centrati insieme.
    NSImage *icon = nil;
    if (self.symbolName) {
        icon = [NSImage imageWithSystemSymbolName:self.symbolName accessibilityDescription:nil];
        // Dimensione e colore vanno applicati all'immagine: il disegno con hint
        // di configurazione non è disponibile su NSImage.
        NSImageSymbolConfiguration *size =
            [NSImageSymbolConfiguration configurationWithPointSize:11 weight:NSFontWeightSemibold];
        NSImageSymbolConfiguration *color =
            [NSImageSymbolConfiguration configurationWithHierarchicalColor:label];
        icon = [icon imageWithSymbolConfiguration:
                [size configurationByApplyingConfiguration:color]];
    }

    NSString *title = self.title ?: @"";
    CGFloat iconWidth = icon ? 15.0 : 0.0;

    // Le lingue non hanno tutte la stessa lunghezza: "Start all" sta ovunque,
    // "Uruchom wszystko" no. Il corpo scende fino a 10 punti pur di far
    // entrare l'etichetta, e solo se non basta il testo viene troncato.
    CGFloat available = NSWidth(self.bounds) - 10.0 - iconWidth;
    NSFont *font = [XPTheme fontBody];
    NSDictionary *attrs = @{NSFontAttributeName: font,
                            NSForegroundColorAttributeName: [label colorWithAlphaComponent:labelAlpha]};
    NSSize textSize = [title sizeWithAttributes:attrs];

    for (CGFloat size = 11.0; textSize.width > available && size >= 9.0; size -= 1.0) {
        font = [NSFont systemFontOfSize:size weight:NSFontWeightMedium];
        attrs = @{NSFontAttributeName: font,
                  NSForegroundColorAttributeName: [label colorWithAlphaComponent:labelAlpha]};
        textSize = [title sizeWithAttributes:attrs];
    }

    if (textSize.width > available) {
        NSMutableDictionary *truncating = [attrs mutableCopy];
        truncating[NSParagraphStyleAttributeName] =
            XPNaturalParagraphStyle(NSLineBreakByTruncatingTail);
        attrs = truncating;
        textSize.width = available;
    }
    CGFloat totalWidth = textSize.width + iconWidth;
    CGFloat x = NSMidX(self.bounds) - totalWidth / 2.0;

    // In RTL il simbolo va dopo il testo, non prima.
    if (icon && XPIsRTL()) {
        NSRect iconRect = NSMakeRect(x + textSize.width + 3, NSMidY(self.bounds) - 6, 12, 12);
        [icon drawInRect:iconRect
                fromRect:NSZeroRect
               operation:NSCompositingOperationSourceOver
                fraction:alpha
          respectFlipped:YES
                   hints:nil];
        icon = nil;
    } else if (icon) {
        NSRect iconRect = NSMakeRect(x, NSMidY(self.bounds) - 6, 12, 12);
        [icon drawInRect:iconRect
                fromRect:NSZeroRect
               operation:NSCompositingOperationSourceOver
                fraction:alpha
          respectFlipped:YES
                   hints:nil];
        x += iconWidth;
    }

    // Si disegna in un rettangolo, non in un punto: è ciò che permette al
    // troncamento di entrare in funzione quando l'etichetta non ci sta.
    [title drawInRect:NSMakeRect(x, NSMidY(self.bounds) - textSize.height / 2.0,
                                 textSize.width, textSize.height)
       withAttributes:attrs];
}

@end
