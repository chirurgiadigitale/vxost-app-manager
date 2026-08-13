//
//  make-icon.m
//  Genera Resources/AppIcon.icns dal logo ufficiale VXOST.
//
//  Il logo di partenza è l'SVG usato dalla dashboard, così app e web root
//  mostrano esattamente lo stesso marchio. macOS carica l'SVG nativamente
//  (_NSSVGImageRep), quindi ogni dimensione viene renderizzata dal vettore
//  e non da un ingrandimento.
//
//  Compilazione e uso:
//      clang -fobjc-arc -framework Cocoa -o build/make-icon tools/make-icon.m
//      ./build/make-icon <logo.svg> <cartella.iconset>
//

#import <Cocoa/Cocoa.h>

/// Percentuale del lato occupata dal marchio: le icone macOS moderne lasciano
/// un margine attorno al contenuto invece di riempire il quadrato.
static const CGFloat XPIconContentRatio = 0.82;

/// Costruisce il profilo arrotondato dell'icona di macOS.
///
/// Non è un rettangolo con angoli circolari ma una superellisse: la curvatura
/// entra e esce dall'angolo con continuità, ed è ciò che distingue la sagoma
/// di sistema da un semplice `bezierPathWithRoundedRect:`.
static NSBezierPath *SquirclePath(NSRect rect) {
    NSBezierPath *path = [NSBezierPath bezierPath];

    CGFloat a = NSWidth(rect) / 2.0;
    CGFloat b = NSHeight(rect) / 2.0;
    CGFloat cx = NSMidX(rect);
    CGFloat cy = NSMidY(rect);

    // Esponente della superellisse: 5 è il valore che più si avvicina alla
    // sagoma usata dalle icone di macOS.
    const CGFloat n = 5.0;
    const NSInteger steps = 720;

    for (NSInteger i = 0; i <= steps; i++) {
        double t = (2.0 * M_PI * i) / steps;
        double ct = cos(t), st = sin(t);

        // Forma parametrica della superellisse, conservando il segno.
        double x = cx + a * copysign(pow(fabs(ct), 2.0 / n), ct);
        double y = cy + b * copysign(pow(fabs(st), 2.0 / n), st);

        if (i == 0) [path moveToPoint:NSMakePoint(x, y)];
        else        [path lineToPoint:NSMakePoint(x, y)];
    }
    [path closePath];
    return path;
}

/// Disegna l'icona alla dimensione richiesta e restituisce i dati PNG.
static NSData *RenderIcon(NSImage *logo, NSInteger side) {
    NSBitmapImageRep *rep =
        [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                                pixelsWide:side
                                                pixelsHigh:side
                                             bitsPerSample:8
                                           samplesPerPixel:4
                                                  hasAlpha:YES
                                                  isPlanar:NO
                                            colorSpaceName:NSCalibratedRGBColorSpace
                                               bytesPerRow:0
                                              bitsPerPixel:0];

    NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:context];
    context.imageInterpolation = NSImageInterpolationHigh;

    CGFloat full = (CGFloat)side;
    CGFloat content = round(full * XPIconContentRatio);
    CGFloat origin = round((full - content) / 2.0);
    NSRect contentRect = NSMakeRect(origin, origin, content, content);

    NSBezierPath *shape = SquirclePath(contentRect);

    // Ombra sotto la sagoma, come nelle icone di sistema. Sotto i 64 px
    // sporcherebbe soltanto, quindi si applica alle dimensioni maggiori.
    if (side >= 64) {
        NSShadow *shadow = [[NSShadow alloc] init];
        shadow.shadowColor = [NSColor colorWithWhite:0 alpha:0.28];
        shadow.shadowOffset = NSMakeSize(0, -full * 0.012);
        shadow.shadowBlurRadius = full * 0.03;
        [NSGraphicsContext saveGraphicsState];
        [shadow set];
        [[NSColor blackColor] setFill];
        [shape fill];
        [NSGraphicsContext restoreGraphicsState];
    }

    // Il marchio viene ritagliato dalla sagoma: il quadrato arancione del logo
    // diventa il corpo dell'icona e il simbolo bianco resta al suo interno.
    [NSGraphicsContext saveGraphicsState];
    [shape addClip];

    // Il viewBox del logo non è perfettamente quadrato: si riempie la sagoma
    // conservando le proporzioni, senza deformare il marchio.
    NSSize logoSize = logo.size;
    CGFloat scale = MAX(content / logoSize.width, content / logoSize.height);
    NSSize drawn = NSMakeSize(logoSize.width * scale, logoSize.height * scale);
    NSRect logoRect = NSMakeRect(NSMidX(contentRect) - drawn.width / 2.0,
                                 NSMidY(contentRect) - drawn.height / 2.0,
                                 drawn.width, drawn.height);
    [logo drawInRect:logoRect
            fromRect:NSZeroRect
           operation:NSCompositingOperationSourceOver
            fraction:1.0];
    [NSGraphicsContext restoreGraphicsState];

    [NSGraphicsContext restoreGraphicsState];
    return [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 3) {
            fprintf(stderr, "Uso: make-icon <logo.svg> <cartella.iconset>\n");
            return 1;
        }

        NSString *logoPath = [NSString stringWithUTF8String:argv[1]];
        NSString *outputDir = [NSString stringWithUTF8String:argv[2]];

        NSImage *logo = [[NSImage alloc] initWithContentsOfFile:logoPath];
        if (!logo) {
            fprintf(stderr, "Errore: impossibile caricare %s\n", argv[1]);
            return 1;
        }

        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:outputDir
      withIntermediateDirectories:YES
                       attributes:nil
                            error:NULL];

        // Nomi e dimensioni richiesti da iconutil.
        NSArray *variants = @[
            @[@"icon_16x16.png",       @16],  @[@"icon_16x16@2x.png",   @32],
            @[@"icon_32x32.png",       @32],  @[@"icon_32x32@2x.png",   @64],
            @[@"icon_128x128.png",    @128],  @[@"icon_128x128@2x.png",@256],
            @[@"icon_256x256.png",    @256],  @[@"icon_256x256@2x.png",@512],
            @[@"icon_512x512.png",    @512],  @[@"icon_512x512@2x.png",@1024],
        ];

        for (NSArray *variant in variants) {
            NSString *name = variant[0];
            NSInteger side = [variant[1] integerValue];

            NSData *png = RenderIcon(logo, side);
            if (!png) {
                fprintf(stderr, "Errore: rendering fallito a %ld px\n", (long)side);
                return 1;
            }
            NSString *destination = [outputDir stringByAppendingPathComponent:name];
            if (![png writeToFile:destination atomically:YES]) {
                fprintf(stderr, "Errore: scrittura fallita per %s\n", name.UTF8String);
                return 1;
            }
            printf("  %-22s %4ld px  %5lu KB\n",
                   name.UTF8String, (long)side, (unsigned long)(png.length / 1024));
        }
        return 0;
    }
}
