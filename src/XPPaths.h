//
//  XPPaths.h
//  Percorsi dell'installazione XAMPP, centralizzati in un punto solo.
//
//  Tutto il resto dell'app passa da qui: se un giorno XAMPP cambia layout
//  si tocca questo file e basta.
//

#import <Foundation/Foundation.h>

/// Radice dell'installazione: /Applications/XAMPP/xamppfiles
extern NSString *const XPRoot;

/// Script di controllo ufficiale (start/stop/reload/backup/ssl/security).
extern NSString *const XPControlScript;

@interface XPPaths : NSObject

/// Percorso assoluto a partire dalla radice XAMPP.
+ (NSString *)root:(NSString *)relative;

/// true se l'installazione XAMPP è presente e lo script di controllo è eseguibile.
+ (BOOL)installationIsValid;

#pragma mark - Log

/// Log di sistema, nell'ordine in cui vanno mostrati nel selettore.
/// Ogni voce: @{@"title": ..., @"path": ...}
+ (NSArray<NSDictionary *> *)systemLogs;

/// Log per singolo virtual host, ricavati da logs/*-error_log e *-access_log.
+ (NSArray<NSDictionary *> *)projectLogs;

#pragma mark - Config

/// File di configurazione apribili dall'app.
+ (NSArray<NSDictionary *> *)configFiles;

/// Document root di Apache.
+ (NSString *)htdocs;

@end
