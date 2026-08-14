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
#import "XPPhpVersion.h"

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
- (void)openVxostFolder;
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

/// Il pannello Informazioni, con release e autore.
- (void)showAbout;

#pragma mark - Nuovo progetto

/// Prima porta libera dopo quelle già dichiarate in httpd.conf.
///
/// Legge le righe `Listen`, comprese quelle commentate: una porta spenta a mano
/// è comunque destinata a un progetto, e riusarla creerebbe un conflitto il
/// giorno in cui viene riattivata.
+ (NSInteger)suggestedPort;

/// Perché il nome non va bene, nil se va bene.
+ (NSString *)validationErrorForProjectName:(NSString *)name;

/// Perché la porta non va bene, nil se va bene.
+ (NSString *)validationErrorForPort:(NSInteger)port;

/// Crea la cartella (o clona il repository), scrive il virtual host, apre la
/// porta e riavvia Apache.
///
/// ⚠️ È l'unica operazione dell'app che scrive sulla configurazione di Apache.
/// Copia i due file prima di toccarli, valida con `httpd -t` e rimette i
/// backup se la validazione fallisce: un httpd.conf malformato lascerebbe giù
/// tutti i progetti locali, non solo quello nuovo.
- (void)createProjectNamed:(NSString *)name
                   summary:(NSString *)summary
                repository:(NSString *)repositoryURL
                      port:(NSInteger)port
               phpVersion:(XPPhpVersion *)phpVersion
                  database:(NSString *)database
                completion:(void (^)(BOOL ok))completion;

#pragma mark - Utilità

/// Diffonde un messaggio verso le interfacce.
- (void)postMessage:(NSString *)message isError:(BOOL)isError;

@end
