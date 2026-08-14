//
//  XPPhpVersion.h
//  Le versioni di PHP che un progetto può usare.
//
//  Una è quella compilata nello stack, servita da mod_php, ed è il default per
//  chiunque non chieda niente. Le altre arrivano da Homebrew e girano come
//  processi php-fpm separati: il virtual host sceglie con SetHandler.
//
//  ⚠️ mod_php ne carica una sola per installazione. Non è una scelta di VXOST,
//  è come funziona il modulo, e per questo la scelta è per progetto e passa da
//  php-fpm.
//

#import <Foundation/Foundation.h>

@interface XPPhpVersion : NSObject

/// "8.2.30", presa dal binario.
@property (nonatomic, copy, readonly) NSString *version;

/// "8.2", quello che si usa per parlarne.
@property (nonatomic, copy, readonly) NSString *shortVersion;

/// Dove sta: la radice VXOST, o il prefisso Homebrew.
@property (nonatomic, copy, readonly) NSString *prefix;

/// Quella dello stack, che passa da mod_php e non ha bisogno di un pool.
@property (nonatomic, assign, readonly) BOOL isBundled;

/// Il socket del suo pool. Nil per quella dello stack, che non ne ha uno.
@property (nonatomic, copy, readonly) NSString *socketPath;

/// Il pool sta girando adesso?
@property (nonatomic, assign, readonly) BOOL poolIsRunning;

/// Tutte quelle utilizzabili, la bundled per prima.
/// Da chiamare fuori dal main thread: interroga i binari.
+ (NSArray<XPPhpVersion *> *)available;

/// Come sopra ma senza rifare la ricerca ogni volta.
///
/// ⚠️ Serve alle viste. Trovare le versioni vuol dire lanciare `php -r` per
/// ogni binario che c'è: farlo a ogni riga della sezione Progetti, a ogni
/// ridisegno, sono decine di processi per una tendina che cambia una volta al
/// mese. Si aggiorna da sé dopo un quarto d'ora, e -[XPPhpVersion forget] la
/// butta via subito.
+ (NSArray<XPPhpVersion *> *)cachedAvailable;

/// Dimentica l'elenco: la prossima richiesta rifà la ricerca.
+ (void)forget;

/// Il blocco da mettere nel virtual host perché il progetto usi questa
/// versione. Stringa vuota per quella dello stack, che è già il default.
- (NSString *)virtualHostDirective;

/// La versione che serve su questo socket, fra quelle disponibili.
/// Passando nil si ottiene quella dello stack, che socket non ne ha.
+ (XPPhpVersion *)versionForSocket:(NSString *)socket;

/// Avvia il pool php-fpm di questa versione, se non gira già.
/// Restituisce il motivo del fallimento, nil se è andata o se non serviva.
///
/// ⚠️ Il pool gira come l'utente, non come root. Un php-fpm di root eseguirebbe
/// il codice dei progetti con tutti i permessi della macchina, ed è un prezzo
/// che non vale la comodità.
///
/// ⏳ E non sopravvive al riavvio del Mac: è un processo lanciato a mano, non
/// un servizio. Finché non c'è un LaunchAgent, un progetto su una versione di
/// Homebrew va riacceso dall'app dopo ogni riavvio.
- (NSString *)startPool;

@end
