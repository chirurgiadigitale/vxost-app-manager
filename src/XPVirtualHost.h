//
//  XPVirtualHost.h
//  Un virtual host di Apache: la porta e il progetto che serve.
//
//  Serve a rispondere alla domanda pratica "la 4002 di chi è?" senza aprire
//  httpd-vhosts.conf, e soprattutto a distinguere una porta chiusa perché
//  Apache è fermo da una chiusa perché il blocco è commentato.
//

#import <Foundation/Foundation.h>
#import "XPGitInfo.h"

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
/// Repository a cui appartiene il progetto servito, nil se non ne ha uno.
@property (nonatomic, strong) XPGitInfo *git;

/// Il socket php-fpm che il blocco indica, nil se il progetto usa la versione
/// compilata nello stack.
///
/// ⚠️ È il socket e non la versione: nel file c'è scritto solo quello. La
/// versione la sa XPPhpVersion, che i socket li costruisce, e i due si
/// incrociano lì.
@property (nonatomic, copy) NSString *phpSocket;

/// Legge httpd-vhosts.conf e restituisce i virtual host in ordine di porta,
/// blocchi commentati compresi. Da chiamare fuori dal main thread.
+ (NSArray<XPVirtualHost *> *)allHosts;

/// Come sopra ma da un file indicato, e senza sondare le porte.
/// Esposto per poter provare il parser su configurazioni di esempio.
+ (NSArray<XPVirtualHost *> *)hostsFromFile:(NSString *)path probePorts:(BOOL)probe;

/// Riscrive una configurazione mettendo, o togliendo, il blocco PHP di un
/// virtual host. Restituisce nil se non c'è niente da cambiare.
///
/// `directive` è quello che produce -[XPPhpVersion virtualHostDirective]:
/// stringa vuota per tornare alla versione dello stack.
///
/// ⚠️ Tocca solo il blocco attivo di quella porta. Un blocco commentato resta
/// com'è: è un progetto spento, e cambiargli il PHP senza che nessuno lo veda
/// vuol dire lasciargli una sorpresa per il giorno in cui lo riaccende.
+ (NSString *)configuration:(NSString *)configuration
                 settingPhp:(NSString *)directive
                    forPort:(NSInteger)port;

/// URL da aprire nel browser.
- (NSURL *)url;

/// Descrizione dello stato, pronta per l'interfaccia.
- (NSString *)stateDescription;

@end
