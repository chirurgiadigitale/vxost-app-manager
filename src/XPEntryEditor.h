//
//  XPEntryEditor.h
//  Correggere una sessione, o scriverne una che non è mai stata cronometrata.
//
//  Perché esiste: il tracker sapeva registrare, sommare ed eliminare, ma non
//  correggere. Chi si accorgeva di aver fermato il cronometro un'ora dopo
//  aveva una sola strada, cancellare tutto, e con l'errore se ne andava anche
//  il lavoro buono. Chi si dimenticava di farlo partire non aveva strada
//  affatto. In uno strumento che serve a sapere quante ore sono andate su un
//  progetto, un dato sbagliato che non si può aggiustare vale meno di nessun
//  dato: si smette di fidarsi del totale, e allora tanto vale non tenerlo.
//
//  Si apre come foglio sulla finestra dello storico, non come finestra a sé:
//  sta correggendo una riga che si vede dietro, e staccarla dal suo contesto
//  la farebbe sembrare un'altra cosa.
//

#import <Cocoa/Cocoa.h>

@class XPTimeEntry;

@interface XPEntryEditor : NSObject

/// Apre la correzione di una sessione esistente.
///
/// `done` viene chiamato solo se qualcosa è cambiato davvero, così chi
/// chiama non ricostruisce l'elenco per un annulla.
+ (void)editEntry:(XPTimeEntry *)entry
        forWindow:(NSWindow *)window
             done:(void (^)(void))done;

/// Apre l'inserimento di una sessione nuova, già conclusa, nel giorno
/// indicato. Le ore proposte sono le ultime due, arrotondate ai cinque
/// minuti: quasi sempre si registra qualcosa appena finito.
+ (void)addEntryOnDay:(NSDate *)day
            forWindow:(NSWindow *)window
                 done:(void (^)(void))done;

@end
