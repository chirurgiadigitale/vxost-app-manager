//
//  XPMainWindowController.h
//  Finestra principale, quella che si apre dall'icona nel Dock.
//
//  Offre le stesse funzioni del popover della barra di stato, con più spazio:
//  servizi, controllo, collegamenti, strumenti e file di configurazione, tutti
//  raggiungibili senza passare da un menu.
//

#import <Cocoa/Cocoa.h>

@interface XPMainWindowController : NSWindowController

+ (instancetype)shared;

/// Mostra la finestra portandola in primo piano.
- (void)present;

@end
