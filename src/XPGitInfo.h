//
//  XPGitInfo.h
//  Il repository a cui appartiene un progetto servito in locale.
//
//  Serve a vedere a colpo d'occhio quale progetto sta su quale repo, senza
//  aprire il Terminale in ogni cartella.
//
//  I file di git si leggono direttamente invece di chiamare `git`: la sezione
//  Progetti si aggiorna spesso e avviare un processo per riga costerebbe più
//  di quanto valga. Basta leggere due file di testo.
//

#import <Foundation/Foundation.h>

@interface XPGitInfo : NSObject

/// Cartella che contiene il .git, che può essere un genitore del DocumentRoot.
@property (nonatomic, copy) NSString *repositoryPath;
/// Forma breve "owner/repo", nil se il remote non è riconoscibile.
@property (nonatomic, copy) NSString *shortName;
/// Indirizzo web del repository, per aprirlo nel browser.
@property (nonatomic, strong) NSURL *webURL;
/// Ramo corrente, nil se la testa è staccata.
@property (nonatomic, copy) NSString *branch;
/// true se il remote è su github.com.
@property (nonatomic, assign) BOOL isGitHub;

/// Cerca il repository partendo dal percorso indicato e risalendo i genitori.
/// Restituisce nil se non ne trova, o se esce dal web root.
+ (instancetype)infoForPath:(NSString *)path;

/// Da un url di remote ricava "owner/repo". Esposto perché è la parte con più
/// varianti in circolazione e va potuta provare da sola.
+ (NSString *)shortNameFromRemote:(NSString *)remote;

/// Indirizzo web corrispondente al remote, anche in forma SSH.
+ (NSURL *)webURLFromRemote:(NSString *)remote;

@end
