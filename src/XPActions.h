//
//  XPActions.h
//  Tutte le operazioni dell'app, in un punto solo.
//
//  Il popover della barra di stato e la finestra del Dock offrono le stesse
//  funzioni: la logica sta qui e viene usata da entrambi, così una correzione
//  vale per tutte e due le interfacce.
//
//  Gli esiti non tornano al chiamante ma vengono diffusi come notifica, perché
//  a un'azione avviata dal popover può interessare anche la finestra, e
//  viceversa.
//

#import <Cocoa/Cocoa.h>
#import "XPService.h"
#import "XPVirtualHost.h"

/// Inviata a ogni esito. userInfo: @{@"message": NSString, @"isError": NSNumber}
extern NSString *const XPActionMessageNotification;

@interface XPActions : NSObject

+ (instancetype)shared;

/// Finestra da usare come genitore per gli avvisi modali.
@property (nonatomic, weak) NSWindow *presentingWindow;

#pragma mark - Servizi

- (void)toggleService:(XPService *)service;
- (void)reloadService:(XPService *)service;
- (void)startAll;
- (void)stopAll;
- (void)restartAll;

#pragma mark - Collegamenti

- (void)openDashboard;
- (void)openPhpMyAdmin;
- (void)openHtdocs;
- (void)openXamppFolder;
- (void)revealFile:(NSString *)path;
/// Apre nel browser il progetto servito da un virtual host.
- (void)openVirtualHost:(XPVirtualHost *)host;

#pragma mark - Strumenti

- (void)enableSSL;
- (void)disableSSL;
/// Esegue il controllo di sicurezza nel Terminale: è interattivo.
- (void)runSecurityCheck;
/// Esegue il backup nel Terminale: è interattivo.
- (void)runBackup;

#pragma mark - Utilità

/// Diffonde un messaggio verso le interfacce.
- (void)postMessage:(NSString *)message isError:(BOOL)isError;

@end
