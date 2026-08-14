//
//  XPExposure.h
//  Chi può raggiungere i progetti serviti da questo Mac.
//
//  ⚠️ Il punto di partenza non è quello che sembra. Lo stack esce con
//  `Listen 80`, `Listen 4000`… **senza indirizzo**, e una Listen senza
//  indirizzo si mette in ascolto su tutte le interfacce. Quindi i progetti
//  sono già raggiungibili da chiunque sia sulla stessa rete, da sempre.
//
//  "Chiuso in modo predefinito" quindi non vuol dire non accendere qualcosa:
//  vuol dire spegnere qualcosa che è acceso, riscrivendo `Listen 4000` in
//  `Listen 127.0.0.1:4000`.
//
//  MariaDB invece è chiuso (bind-address=127.0.0.1). Oggi la situazione è
//  Apache aperto e database chiuso, il che vuol dire che un progetto aperto
//  dal telefono funziona solo se non gli serve il database.
//
//  ⚠️ Non è un booleano. Domani Gateway aggiunge un terzo valore, e un
//  interruttore aperto/chiuso andrebbe riscritto da capo per farcelo stare.
//

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, XPExposureScope) {
    /// Le Listen non concordano fra loro: qualcuna ha un indirizzo, qualcuna
    /// no. Succede a chi ha modificato il file a mano, e va detto invece di
    /// scegliere per lui.
    XPExposureScopeMixed = 0,

    /// Solo questo Mac. `Listen 127.0.0.1:4000`.
    XPExposureScopeThisMac,

    /// Questo Mac e chi è sulla stessa rete. `Listen 4000`.
    XPExposureScopeLocalNetwork,

    /// ⏳ Riservato a Gateway, primavera 2027. Non è ancora selezionabile.
    XPExposureScopeInternet,
};

@interface XPExposure : NSObject

/// Com'è adesso, letto dai file di configurazione.
+ (XPExposureScope)currentScope;

/// Le porte dichiarate, in ordine. Le righe commentate non ci sono.
+ (NSArray<NSNumber *> *)listenedPorts;

/// I file che contengono direttive Listen. Sono due: httpd.conf e la
/// configurazione SSL, e dimenticare la seconda lascia la 443 aperta mentre
/// tutto il resto è chiuso.
+ (NSArray<NSString *> *)configurationFiles;

/// Riscrive una configurazione in memoria, senza toccare il disco.
/// Restituisce nil se non c'è niente da cambiare.
///
/// ⚠️ Le righe commentate non si toccano. In httpd.conf c'è
/// `#Listen 12.34.56.78:80`, che è l'esempio della documentazione di Apache:
/// riscriverlo lo rovinerebbe. È lo stesso motivo per cui il ServerAlias non
/// si aggiunge con una regex.
+ (NSString *)rewrite:(NSString *)configuration toScope:(XPExposureScope)scope;

/// Applica la scelta: copia di sicurezza, riscrittura, `httpd -t`, ripristino
/// se il test fallisce, e solo dopo il riavvio. Chiede la password una volta.
///
/// L'esito arriva come XPActionMessageNotification, come tutto il resto.
+ (void)applyScope:(XPExposureScope)scope completion:(void (^)(BOOL ok))completion;

/// Il nome da mostrare.
+ (NSString *)nameForScope:(XPExposureScope)scope;

@end
