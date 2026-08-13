//
//  XPService.h
//  Un servizio VXOST (Apache, MySQL, ProFTPD) e il suo stato.
//

#import <Cocoa/Cocoa.h>

typedef NS_ENUM(NSInteger, XPServiceState) {
    XPServiceStateStopped = 0,
    XPServiceStateRunning,
    XPServiceStateBusy       ///< transizione in corso (start/stop lanciato)
};

@interface XPService : NSObject

@property (nonatomic, copy,   readonly) NSString *key;        ///< apache | mysql | ftp
@property (nonatomic, copy,   readonly) NSString *name;       ///< nome mostrato
@property (nonatomic, copy,   readonly) NSString *matchPattern; ///< pattern per pgrep -f
@property (nonatomic, copy,   readonly) NSString *startAction;  ///< azione dello script vxost
@property (nonatomic, copy,   readonly) NSString *stopAction;
@property (nonatomic, copy,   readonly) NSString *reloadAction;
@property (nonatomic, strong, readonly) NSColor  *tint;       ///< colore semantico dal design system

@property (nonatomic, assign) XPServiceState state;
@property (nonatomic, assign) pid_t          pid;
@property (nonatomic, copy)   NSArray<NSNumber *> *configuredPorts; ///< porte da configurazione
@property (nonatomic, copy)   NSArray<NSNumber *> *listeningPorts;  ///< porte che rispondono davvero

/// I tre servizi, nell'ordine di visualizzazione.
+ (NSArray<XPService *> *)allServices;

/// Qualcuno è in ascolto su quella porta di 127.0.0.1?
///
/// Esposta qui perché la stessa domanda se la pongono anche i virtual host e
/// il wizard dei progetti, e la risposta era finita duplicata in tre file.
/// `lsof` non va bene: da utente normale non vede i processi di root.
+ (BOOL)portIsListening:(uint16_t)port timeout:(NSTimeInterval)timeout;

/// Rilegge stato, pid e porte in ascolto. Da chiamare fuori dal main thread.
- (void)refresh;

/// Descrizione compatta delle porte, es. "80, 443" oppure "80, 443, 4000 +4".
- (NSString *)portsDescription;

/// Elenco completo delle porte, per il tooltip.
- (NSString *)allPortsDescription;

@end
