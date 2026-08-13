//
//  XPPaths.h
//  Percorsi dell'installazione VXOST, centralizzati in un punto solo.
//
//  Tutto il resto dell'app passa da qui: se un giorno VXOST cambia layout
//  si tocca questo file e basta.
//

#import <Foundation/Foundation.h>

@interface XPPaths : NSObject

/// La radice dell'installazione, decisa a runtime.
///
/// Non e' una costante perche' non puo' esserlo: durante la transizione dei
/// nomi convivono la vecchia cartella e la nuova, e un percorso compilato
/// rende l'app inservibile su meta' delle macchine.
+ (NSString *)installRoot;

/// Lo script di controllo dentro quella radice
/// (start/stop/reload/backup/ssl/security).
+ (NSString *)controlScript;

/// Percorso assoluto a partire dalla radice VXOST.
+ (NSString *)root:(NSString *)relative;

/// true se l'installazione VXOST è presente e lo script di controllo è eseguibile.
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

/// Versione di VXOST installata, letta da lib/VERSION (es. "8.2.4").
/// Nil se il file manca.
+ (NSString *)vxostVersion;

@end
