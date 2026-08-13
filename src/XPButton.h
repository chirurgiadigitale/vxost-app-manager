//
//  XPButton.h
//  Pulsante disegnato a mano, con i token del design system della dashboard.
//
//  NSButton di sistema non permette di controllare riempimento, bordo e stato
//  hover con la precisione che serve qui, quindi la vista si disegna da sé.
//

#import <Cocoa/Cocoa.h>

typedef NS_ENUM(NSInteger, XPButtonStyle) {
    XPButtonStylePrimary,  ///< pieno, magenta accento
    XPButtonStyleGhost,    ///< superficie tenue con bordo
    XPButtonStyleDanger,   ///< bordo e testo rossi
    XPButtonStyleQuiet     ///< solo testo, per il footer
};

@interface XPButton : NSView

@property (nonatomic, copy)   NSString *title;
@property (nonatomic, copy)   NSString *symbolName;   ///< SF Symbol opzionale a sinistra
@property (nonatomic, assign) XPButtonStyle style;
@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, copy)   void (^onClick)(XPButton *sender);

+ (instancetype)buttonWithTitle:(NSString *)title
                          style:(XPButtonStyle)style
                        onClick:(void (^)(XPButton *))onClick;

@end
