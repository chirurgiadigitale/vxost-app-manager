//
//  XPServiceRowView.h
//  Una riga del pannello: indicatore di stato, nome, porte e PID, pulsante.
//

#import <Cocoa/Cocoa.h>
#import "XPService.h"

@interface XPServiceRowView : NSView

@property (nonatomic, strong, readonly) XPService *service;

/// Chiamata quando l'utente preme il pulsante di avvio/arresto.
@property (nonatomic, copy) void (^onToggle)(XPService *service);
/// Chiamata quando l'utente sceglie "Ricarica" dal menu contestuale.
@property (nonatomic, copy) void (^onReload)(XPService *service);

- (instancetype)initWithService:(XPService *)service;

/// Rilegge lo stato dal modello e ridisegna.
- (void)refresh;

@end
