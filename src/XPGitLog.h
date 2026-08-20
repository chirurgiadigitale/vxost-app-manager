//
//  XPGitLog.h
//  I commit di un giorno, accanto alle ore di quel giorno.
//
//  Perché serve: lo storico dice quante ore sono andate su un progetto, ma non
//  che cosa è successo. A distanza di settimane "4h 20m su listeoo" non dice
//  niente; l'elenco dei commit di quel giorno lo dice per intero, ed è già
//  scritto — solo, sta in un altro posto e nessuno va a ripescarlo.
//
//  ⚠️ Qui si chiama `git`, mentre XPGitInfo legge i file a mano di proposito.
//  La differenza è la frequenza: la sezione Progetti si ridisegna in continuo
//  e avviare un processo per riga costerebbe più di quanto valga, lo storico
//  si apre e si guarda. Ricostruire un `git log` leggendo gli oggetti del
//  repository sarebbe scrivere metà di git per risparmiare una fork.
//
//  ⛔ Nessuna rete e nessun account: i commit stanno già sul disco. Il
//  collegamento con GitHub serve solo a costruire l'indirizzo da aprire nel
//  browser, e quello lo sa già fare XPGitInfo.
//

#import <Foundation/Foundation.h>

@interface XPCommit : NSObject
/// L'abbreviazione che git stesso usa, sette caratteri o più se servono.
@property (nonatomic, copy) NSString *shortHash;
@property (nonatomic, copy) NSString *subject;
@property (nonatomic, copy) NSString *author;
@property (nonatomic, strong) NSDate *date;
/// Indirizzo del commit sul remote, nil se il remote non è riconosciuto.
@property (nonatomic, strong) NSURL *webURL;
@end


@interface XPGitLog : NSObject

/// I commit fatti nel giorno indicato dentro il repository che contiene
/// `path`, dal più recente. Array vuoto se non è un repository, se git non
/// risponde o se quel giorno non è successo niente.
///
/// Il filtro è sulla data di autore, non su quella di commit: un rebase
/// sposta la seconda e l'ora del lavoro non c'entra più niente.
+ (NSArray<XPCommit *> *)commitsForPath:(NSString *)path onDay:(NSDate *)day;

/// Il percorso su disco di un progetto del tracker, ricavato dalla sua
/// chiave. Restituisce nil per le voci create a mano, che non hanno cartella.
+ (NSString *)pathForProjectKey:(NSString *)key;

@end
