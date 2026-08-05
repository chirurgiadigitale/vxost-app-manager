//
//  XPLogWindowController.h
//  Visualizzatore di log.
//
//  Legge sempre e solo la coda del file: il .err di MySQL può arrivare a
//  diversi gigabyte e caricarlo in memoria bloccherebbe l'app.
//

#import <Cocoa/Cocoa.h>

@interface XPLogWindowController : NSWindowController

+ (instancetype)shared;

/// Mostra la finestra, ricaricando l'elenco dei log disponibili.
- (void)showWindowAndReload;

@end
