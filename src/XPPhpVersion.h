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

/// Il blocco da mettere nel virtual host perché il progetto usi questa
/// versione. Stringa vuota per quella dello stack, che è già il default.
- (NSString *)virtualHostDirective;

@end
