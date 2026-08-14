//
//  XPUpdateCheck.h
//  Sapere che è uscita una versione nuova senza andarla a cercare.
//
//  ⚠️ È l'unica richiesta di rete che l'app fa, e va detto dov'è scritto che
//  non ne fa nessuna: la pagina /privacy/ e la pagina /brand/ del sito.
//  Cambiare questo file senza cambiare quelle pagine le rende false.
//
//  Cosa esce dal Mac: una GET a https://vxost.com/version.json, senza cookie,
//  senza identificatori, senza la versione installata. Il confronto lo fa
//  l'app dopo aver ricevuto il file, non il server. Cosa il server può
//  dedurne: che qualcuno ha controllato, e da quale indirizzo IP, come per
//  qualsiasi pagina web aperta.
//
//  Si può spegnere, e spento non parte una sola richiesta.
//

#import <Foundation/Foundation.h>

/// Arriva quando un controllo finisce, riuscito o no.
/// userInfo: "available" (NSNumber), "version" (NSString), "url" (NSString).
extern NSString *const XPUpdateCheckDidFinishNotification;

@interface XPUpdateCheck : NSObject

+ (instancetype)shared;

/// Il controllo automatico è acceso? Lo è finché non lo si spegne.
@property (nonatomic, assign) BOOL automatic;

/// La versione trovata l'ultima volta, se è più recente di questa. Nil se non
/// c'è niente di nuovo o se non si è ancora controllato.
@property (nonatomic, copy, readonly) NSString *availableVersion;

/// Dove si scarica quella versione.
@property (nonatomic, copy, readonly) NSString *downloadURL;

/// Quando è stato fatto l'ultimo controllo, nil se mai.
@property (nonatomic, copy, readonly) NSDate *lastCheck;

/// Avvia il controllo periodico. Da chiamare una volta, all'avvio dell'app.
///
/// Non controlla subito: aspetta qualche secondo, perché l'avvio è il momento
/// in cui l'utente sta aspettando la finestra, non una richiesta di rete.
- (void)start;

/// Controlla adesso, anche se il controllo automatico è spento e anche se si
/// è già controllato oggi. È quello che fa la voce di menu.
- (void)checkNow;

/// Confronto fra numeri di versione: -1, 0, 1.
///
/// ⚠️ Non è un confronto fra stringhe. "9.9.0" è più recente di "9.26.0" per
/// l'ordine alfabetico, e non lo è.
+ (NSComparisonResult)compareVersion:(NSString *)a with:(NSString *)b;

@end
