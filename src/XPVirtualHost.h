//
//  XPVirtualHost.h
//  Un virtual host di Apache: la porta e il progetto che serve.
//
//  Serve a rispondere alla domanda pratica "la 4002 di chi è?" senza aprire
//  httpd-vhosts.conf, e soprattutto a distinguere una porta chiusa perché
//  Apache è fermo da una chiusa perché il blocco è commentato.
//

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, XPVHostState) {
    XPVHostStateListening = 0,  ///< la porta risponde
    XPVHostStateStopped,        ///< configurato e attivo, ma la porta non risponde
    XPVHostStateDisabled        ///< blocco commentato nella configurazione
};

@interface XPVirtualHost : NSObject

@property (nonatomic, assign) NSInteger  port;
@property (nonatomic, copy)   NSString  *documentRoot;  ///< percorso completo
@property (nonatomic, copy)   NSString  *name;          ///< nome breve del progetto
@property (nonatomic, copy)   NSString  *serverName;
@property (nonatomic, assign) XPVHostState state;

/// Legge httpd-vhosts.conf e restituisce i virtual host in ordine di porta,
/// blocchi commentati compresi. Da chiamare fuori dal main thread.
+ (NSArray<XPVirtualHost *> *)allHosts;

/// Come sopra ma da un file indicato, e senza sondare le porte.
/// Esposto per poter provare il parser su configurazioni di esempio.
+ (NSArray<XPVirtualHost *> *)hostsFromFile:(NSString *)path probePorts:(BOOL)probe;

/// URL da aprire nel browser.
- (NSURL *)url;

/// Descrizione dello stato, pronta per l'interfaccia.
- (NSString *)stateDescription;

@end
