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

@end
