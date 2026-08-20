//
//  XPTimerSectionView.h
//  Sezione del cronometro: sessione in corso, registrazioni di oggi, progetti.
//
//  Costruita con Auto Layout: è la prima vista pensata per adattarsi alla
//  larghezza, così la finestra può diventare ridimensionabile e a tutto
//  schermo senza lasciare mezzo schermo vuoto.
//

#import <Cocoa/Cocoa.h>

@interface XPTimerSectionView : NSView

- (instancetype)init;

/// Rilegge lo stato dal tracker e aggiorna quanto serve.
- (void)refresh;

/// Riga di una sessione conclusa: nome, durata e orari.
/// Esposta perché la usa anche la finestra dello storico, e le due devono
/// avere lo stesso aspetto.
+ (NSView *)rowForEntry:(id)entry formatter:(NSDateFormatter *)formatter;

/// La stessa riga, lasciando libero uno spazio a destra.
///
/// Serve allo storico, che ci mette i pulsanti di modifica ed eliminazione.
/// Nel popover non ci sono: lì lo spazio è poco e la riga è di sola lettura.
+ (NSView *)rowForEntry:(id)entry
              formatter:(NSDateFormatter *)formatter
          trailingInset:(CGFloat)inset;

@end
