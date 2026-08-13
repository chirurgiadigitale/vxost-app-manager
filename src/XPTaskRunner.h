//
//  XPTaskRunner.h
//  Esecuzione dei comandi, con e senza privilegi di amministratore.
//
//  I comandi privilegiati passano da /usr/bin/osascript con
//  "do shell script ... with administrator privileges": è lo stesso
//  meccanismo del manager originale, mostra il pannello password nativo
//  di macOS e non richiede di toccare /etc/sudoers.
//
//  osascript viene lanciato come processo esterno via NSTask, quindi non
//  esistono i vincoli di thread di NSAppleScript e nulla blocca la UI.
//

#import <Foundation/Foundation.h>

/// Esito di un comando.
@interface XPTaskResult : NSObject
@property (nonatomic, copy)   NSString *output;     ///< stdout + stderr
@property (nonatomic, assign) int       status;     ///< exit code
@property (nonatomic, assign) BOOL      cancelled;  ///< l'utente ha annullato il pannello password
@property (nonatomic, readonly) BOOL    succeeded;
@end


@interface XPTaskRunner : NSObject

/// Esegue un comando senza privilegi. Sincrono, per letture rapide (pgrep, lsof).
+ (XPTaskResult *)run:(NSString *)launchPath arguments:(NSArray<NSString *> *)arguments;

/// Esegue `vxost <action>` come amministratore, in background.
/// Il completion arriva sul main thread.
+ (void)runPrivilegedVxostAction:(NSString *)action
                      completion:(void (^)(XPTaskResult *result))completion;

/// Esegue una riga di shell arbitraria come amministratore, in background.
/// Usato per le azioni composte (es. backup con percorso di destinazione).
+ (void)runPrivilegedShell:(NSString *)shellCommand
                completion:(void (^)(XPTaskResult *result))completion;

@end
