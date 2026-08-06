//
//  XPLayout.m
//

#import "XPLayout.h"

BOOL XPIsRTL(void) {
    // Segue la direzione decisa da macOS per l'app, che dipende dalla lingua
    // effettivamente in uso: non basta controllare se la lingua è l'urdu,
    // perché l'utente può forzarne un'altra dalle preferenze di sistema.
    return NSApp.userInterfaceLayoutDirection == NSUserInterfaceLayoutDirectionRightToLeft;
}

NSRect XPMirror(NSRect rect, CGFloat containerWidth) {
    if (!XPIsRTL()) return rect;
    rect.origin.x = containerWidth - NSMaxX(rect);
    return rect;
}

CGFloat XPMirrorX(CGFloat x, CGFloat width, CGFloat containerWidth) {
    if (!XPIsRTL()) return x;
    return containerWidth - x - width;
}

NSParagraphStyle *XPNaturalParagraphStyle(NSLineBreakMode lineBreakMode) {
    NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
    style.alignment = NSTextAlignmentNatural;
    style.lineBreakMode = lineBreakMode;
    // Senza questo, una stringa araba dentro un testo latino (o viceversa)
    // verrebbe disposta secondo la direzione del primo carattere invece che
    // secondo quella dell'interfaccia.
    style.baseWritingDirection = XPIsRTL() ? NSWritingDirectionRightToLeft
                                           : NSWritingDirectionLeftToRight;
    return style;
}
