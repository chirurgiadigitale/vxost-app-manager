//
//  XPHistoryWindowController.h
//  Storico delle sessioni: i giorni passati, non solo oggi.
//
//  A sinistra i giorni con il totale, a destra le sessioni del giorno scelto
//  e i totali per progetto.
//

#import <Cocoa/Cocoa.h>

@interface XPHistoryWindowController : NSWindowController

+ (instancetype)shared;

/// Mostra la finestra, ricaricando i dati.
- (void)present;

@end
