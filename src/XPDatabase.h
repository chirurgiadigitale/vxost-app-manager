//
//  XPDatabase.h
//  Creazione del database per un progetto nuovo.
//
//  Serve al wizard: un progetto quasi sempre vuole un database, e crearlo a
//  mano in phpMyAdmin dopo aver creato il progetto è un passaggio che si
//  dimentica, con l'errore di connessione che arriva dieci minuti dopo.
//
//  ⚠️ La password di root non è sempre vuota. Lo stack ne esce senza, ma
//  chiunque abbia lanciato mysql_secure_installation o il controllo di
//  sicurezza ne ha una. Quindi si prova senza, e solo se non basta si chiede,
//  una volta sola, e si tiene nel portachiavi.
//

#import <Foundation/Foundation.h>

@interface XPDatabase : NSObject

/// Il server risponde? Con la password che si ha, o senza.
+ (BOOL)isReachable;

/// Serve una password per entrare come root?
+ (BOOL)needsPassword;

/// Questa password fa entrare come root?
/// Da chiamare fuori dal main thread: parla con il server.
+ (BOOL)passwordWorks:(NSString *)password;

/// La password salvata nel portachiavi, nil se non ce n'è una.
+ (NSString *)storedPassword;

/// Salva la password nel portachiavi. Passare nil la cancella.
+ (void)storePassword:(NSString *)password;

/// Il nome è utilizzabile come nome di database?
/// Restituisce il motivo del rifiuto, nil se va bene.
+ (NSString *)validationErrorForDatabaseName:(NSString *)name;

/// Esiste già un database con questo nome?
+ (BOOL)databaseExists:(NSString *)name;

/// Crea il database, e un utente che ci lavora sopra se ne viene chiesto uno.
///
/// Passando nil come utente si crea il solo database: in locale ci si collega
/// come root, e una credenziale in più è una cosa in più da ricordare.
///
/// Restituisce il motivo del fallimento, nil se è andata. Da chiamare fuori
/// dal main thread: parla con il server e può metterci un istante.
+ (NSString *)createDatabase:(NSString *)database
                        user:(NSString *)user
                    password:(NSString *)password;

@end
