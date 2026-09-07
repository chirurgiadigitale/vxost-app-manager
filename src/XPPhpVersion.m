//
//  XPPhpVersion.m
//

#import "XPPhpVersion.h"
#include <sys/socket.h>         // connect(), per sapere se il pool ascolta
#include <sys/un.h>
#include <unistd.h>             // close()
#include <string.h>
#import "XPPaths.h"
#import "XPTaskRunner.h"

/// ⚠️ /tmp e non NSTemporaryDirectory().
///
/// Su macOS la cartella temporanea dell'utente è /var/folders/<hash>/T ed è
/// drwx------ sua: Apache gira come daemon e non riesce nemmeno ad
/// attraversarla per arrivare al socket. È lo stesso muro contro cui aveva
/// sbattuto mkcert, e vale la pena scriverlo perché la tentazione di usare la
/// cartella "giusta" torna ogni volta.
static NSString *const XPPoolDirectory = @"/tmp";

@interface XPPhpVersion () {
    /// Impostata da startPool: dice se il socket e' rimasto chiuso agli altri
    /// utenti o se php-fpm ha costretto a riaprirlo.
    BOOL _socketIsRestricted;
}
@property (nonatomic, copy) NSString *version;
@property (nonatomic, copy) NSString *prefix;
@property (nonatomic, assign) BOOL isBundled;
@end

@implementation XPPhpVersion

+ (instancetype)versionAtPrefix:(NSString *)prefix bundled:(BOOL)bundled {
    NSString *binary = [prefix stringByAppendingPathComponent:@"bin/php"];
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:binary]) return nil;

    XPTaskResult *result = [XPTaskRunner run:binary
                                   arguments:@[@"-r", @"echo PHP_VERSION;"]];
    NSString *version = [result.output stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!result.succeeded || version.length == 0) return nil;

    // Senza php-fpm la versione non può servire un progetto: si può usare solo
    // da riga di comando, e metterla nell'elenco sarebbe una scelta che poi
    // non funziona.
    if (!bundled) {
        NSString *fpm = [prefix stringByAppendingPathComponent:@"sbin/php-fpm"];
        if (![[NSFileManager defaultManager] isExecutableFileAtPath:fpm]) return nil;
    }

    XPPhpVersion *object = [[XPPhpVersion alloc] init];
    object.version = version;
    object.prefix = prefix;
    object.isBundled = bundled;
    return object;
}

+ (NSArray<XPPhpVersion *> *)available {
    NSMutableArray<XPPhpVersion *> *found = [NSMutableArray array];
    NSFileManager *fm = [NSFileManager defaultManager];

    // Quella dello stack per prima: è il default, e in un elenco il default sta
    // in cima.
    XPPhpVersion *bundled = [self versionAtPrefix:[XPPaths installRoot] bundled:YES];
    if (bundled) [found addObject:bundled];

    // Homebrew, su Apple Silicon e su Intel.
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSString *base in @[@"/opt/homebrew/opt", @"/usr/local/opt"]) {
        NSArray *entries = [fm contentsOfDirectoryAtPath:base error:NULL];
        for (NSString *entry in [entries sortedArrayUsingSelector:@selector(compare:)]) {
            if (![entry isEqualToString:@"php"] && ![entry hasPrefix:@"php@"]) continue;

            XPPhpVersion *version = [self versionAtPrefix:
                                     [base stringByAppendingPathComponent:entry]
                                                  bundled:NO];
            if (!version) continue;

            // php e php@8.5 possono essere la stessa versione: si tiene una
            // voce sola, o l'elenco mostra due scelte identiche.
            if ([seen containsObject:version.shortVersion]) continue;
            [seen addObject:version.shortVersion];
            [found addObject:version];
        }
    }
    return found;
}

/// L'elenco tenuto da parte, e quando è stato fatto.
static NSArray<XPPhpVersion *> *sCached = nil;
static NSDate *sCachedAt = nil;

+ (NSArray<XPPhpVersion *> *)cachedAvailable {
    @synchronized (self) {
        // Un quarto d'ora: abbastanza perché una tendina non costi niente,
        // abbastanza poco perché un `brew install php@8.4` si veda senza
        // riavviare l'app.
        if (sCached && sCachedAt &&
            [[NSDate date] timeIntervalSinceDate:sCachedAt] < 900) {
            return sCached;
        }
    }
    NSArray<XPPhpVersion *> *found = [self available];
    @synchronized (self) {
        sCached = found;
        sCachedAt = [NSDate date];
    }
    return found;
}

+ (void)forget {
    @synchronized (self) {
        sCached = nil;
        sCachedAt = nil;
    }
}

- (NSString *)shortVersion {
    NSArray *parts = [self.version componentsSeparatedByString:@"."];
    if (parts.count < 2) return self.version;
    return [NSString stringWithFormat:@"%@.%@", parts[0], parts[1]];
}

/// Se il socket del pool e' chiuso agli altri utenti della macchina.
/// Vale solo dopo startPool: prima non c'e' nessun socket di cui dirlo.
- (BOOL)socketIsRestricted {
    return _socketIsRestricted;
}

- (NSString *)socketPath {
    if (self.isBundled) return nil;
    NSString *compact = [self.shortVersion stringByReplacingOccurrencesOfString:@"."
                                                                    withString:@""];
    return [XPPoolDirectory stringByAppendingPathComponent:
            [NSString stringWithFormat:@"vxost-php%@.sock", compact]];
}

- (BOOL)poolIsRunning {
    NSString *path = self.socketPath;
    if (!path) return YES;     // mod_php è dentro Apache: se Apache gira, c'è.

    NSDictionary *attributes = [[NSFileManager defaultManager]
                                attributesOfItemAtPath:path error:NULL];
    if (![attributes[NSFileType] isEqualToString:NSFileTypeSocket]) return NO;

    // ⚠️ Il file non e' il servizio.
    //
    // Un socket di dominio unix resta sul disco quando il processo che lo ha
    // aperto muore male: dopo un crash del pool il file c'e' ancora, con il
    // suo bel tipo "socket", e questo metodo rispondeva di si'. La
    // conseguenza si vede altrove: startPool esce subito perche' crede che il
    // pool giri, Apache prova a parlargli e riceve un rifiuto, e il progetto
    // risponde 502 mentre l'app mostra tutto in ordine.
    //
    // L'unica prova che qualcuno stia ascoltando e' provare a connettersi. Il
    // socket e' locale: la connessione riesce o viene rifiutata subito, senza
    // attese che valga la pena rendere asincrone.
    const char *fsPath = path.fileSystemRepresentation;
    struct sockaddr_un address;
    if (!fsPath || strlen(fsPath) >= sizeof(address.sun_path)) {
        // Percorso troppo lungo per sockaddr_un: non si puo' verificare, e
        // dire di no farebbe riavviare un pool che magari sta girando.
        return YES;
    }

    int descriptor = socket(AF_UNIX, SOCK_STREAM, 0);
    if (descriptor < 0) return YES;      // non e' colpa del pool

    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    strlcpy(address.sun_path, fsPath, sizeof(address.sun_path));

    BOOL listening = connect(descriptor, (struct sockaddr *)&address,
                             sizeof(address)) == 0;
    close(descriptor);
    return listening;
}

- (NSString *)virtualHostDirective {
    // Quella dello stack è già il default: aggiungere un blocco che dice di
    // usare mod_php non serve, e un blocco in meno è una cosa in meno che può
    // rompersi.
    if (self.isBundled) return @"";

    return [NSString stringWithFormat:
        @"    # PHP %@ through its own php-fpm pool. Without this block the\n"
        @"    # project uses the version compiled into the stack.\n"
        @"    <FilesMatch \"\\.php$\">\n"
        @"        SetHandler \"proxy:unix:%@|fcgi://localhost\"\n"
        @"    </FilesMatch>\n",
        self.version, self.socketPath];
}

+ (XPPhpVersion *)versionForSocket:(NSString *)socket {
    NSArray<XPPhpVersion *> *all = [self cachedAvailable];
    if (socket.length == 0) {
        for (XPPhpVersion *version in all) {
            if (version.isBundled) return version;
        }
        return all.firstObject;
    }
    for (XPPhpVersion *version in all) {
        if ([version.socketPath isEqualToString:socket]) return version;
    }
    // ⚠️ Nil, non "quella dello stack". Un socket che nessuna versione
    // installata produce vuol dire che il progetto punta a un PHP che qui non
    // c'è: dirlo è utile, sostituirlo in silenzio con un altro no.
    return nil;
}

/// La configurazione del pool, nelle due forme in cui puo' servire.
///
/// ⚠️ Il socket sta in /tmp, che e' attraversabile da chiunque. Con
/// `listen.mode = 0666` qualunque altro utente della macchina puo' aprirlo e
/// parlare FastCGI al pool, cioe' far eseguire PHP con l'identita' di chi lo
/// ha avviato: i suoi file, le sue chiavi, i suoi database. Su un Mac
/// personale non cambia niente, su una macchina condivisa e' un passaggio di
/// identita' completo.
///
/// La forma `restricted` chiude il socket a 0600 e lascia entrare Apache con
/// una ACL. Non serve root: l'ACL la mette php-fpm sul proprio socket.
///
/// ⚠️ Non tutti i php-fpm hanno il supporto ACL compilato (serve
/// --with-fpm-acl). Dove manca, php-fpm rifiuta la direttiva e non parte:
/// per questo esiste anche la forma aperta, e startPool ripiega da sola.
- (NSString *)poolConfigurationRestricted:(BOOL)restricted
                                  pidPath:(NSString *)pidPath
                                  logPath:(NSString *)logPath {
    NSString *access = restricted
        ? @"listen.mode = 0600\n"
          @"; daemon e' l'utente di Apache nello stack, come da httpd.conf.\n"
          @"listen.acl_users = daemon\n"
        : @"listen.mode = 0666\n";

    return [NSString stringWithFormat:
        @"; Generato da VXOST. Si può cancellare, viene riscritto al prossimo avvio.\n"
        @"[global]\n"
        @"pid = %@\n"
        @"error_log = %@\n"
        @"daemonize = yes\n"
        @"\n"
        @"[vxost]\n"
        @"listen = %@\n"
        @"%@"
        @"\n"
        @"pm = dynamic\n"
        @"pm.max_children = 10\n"
        @"pm.start_servers = 2\n"
        @"pm.min_spare_servers = 1\n"
        @"pm.max_spare_servers = 3\n",
        pidPath, logPath, self.socketPath, access];
}

/// Scrive la configurazione, lancia php-fpm e aspetta il socket.
/// Restituisce nil se il pool e' vivo, altrimenti il motivo.
- (NSString *)launchPoolWithConfiguration:(NSString *)configuration
                                     path:(NSString *)confPath
                                      fpm:(NSString *)fpm {
    NSError *error = nil;
    if (![configuration writeToFile:confPath atomically:YES
                           encoding:NSUTF8StringEncoding error:&error]) {
        return error.localizedDescription;
    }

    XPTaskResult *result = [XPTaskRunner run:fpm
                                   arguments:@[@"--fpm-config", confPath]];
    if (!result.succeeded) {
        // L'output del passo che può fallire non si butta via: senza, l'unica
        // cosa che si saprebbe è che è fallito, cioè l'unica già ovvia.
        NSString *why = [result.output stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        return why.length > 0 ? why : NSLocalizedString(@"php.err.pool", nil);
    }

    // Il socket compare un istante dopo il fork, non subito: senza questa
    // attesa Apache riceverebbe la configurazione nuova prima che ci sia
    // qualcuno dall'altra parte, e il progetto darebbe 503.
    for (int i = 0; i < 20 && !self.poolIsRunning; i++) {
        [NSThread sleepForTimeInterval:0.25];
    }
    return self.poolIsRunning ? nil : NSLocalizedString(@"php.err.pool", nil);
}

- (NSString *)startPool {
    if (self.isBundled) return nil;         // mod_php sta dentro Apache
    if (self.poolIsRunning) return nil;

    NSString *fpm = [self.prefix stringByAppendingPathComponent:@"sbin/php-fpm"];
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:fpm]) {
        return NSLocalizedString(@"php.err.nofpm", nil);
    }

    NSString *compact = [self.shortVersion stringByReplacingOccurrencesOfString:@"."
                                                                     withString:@""];
    NSString *pidPath = [XPPoolDirectory stringByAppendingPathComponent:
                         [NSString stringWithFormat:@"vxost-php%@.pid", compact]];
    NSString *logPath = [XPPoolDirectory stringByAppendingPathComponent:
                         [NSString stringWithFormat:@"vxost-php%@.log", compact]];
    NSString *confPath = [XPPoolDirectory stringByAppendingPathComponent:
                          [NSString stringWithFormat:@"vxost-php%@.conf", compact]];

    // Prima si prova a tenere il socket chiuso.
    NSString *why = [self launchPoolWithConfiguration:
                     [self poolConfigurationRestricted:YES
                                               pidPath:pidPath
                                               logPath:logPath]
                                                 path:confPath
                                                  fpm:fpm];
    if (!why) {
        _socketIsRestricted = YES;
        return nil;
    }

    // php-fpm senza supporto ACL non parte affatto. Fra un pool esposto e
    // nessun pool, il primo almeno funziona: si ripiega, ma resta scritto
    // nel log di sistema, perché una rinuncia silenziosa alla sicurezza
    // non e' una rinuncia, e' una bugia.
    NSLog(@"VXOST: php-fpm %@ non ha accettato la ACL sul socket (%@). "
          @"Il pool riparte con il socket aperto in lettura e scrittura a "
          @"tutti gli utenti di questo Mac.", self.version, why);

    why = [self launchPoolWithConfiguration:
           [self poolConfigurationRestricted:NO pidPath:pidPath logPath:logPath]
                                       path:confPath
                                        fpm:fpm];
    _socketIsRestricted = NO;
    return why;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"PHP %@%@", self.version,
            self.isBundled ? @" (in the box)" : @" (Homebrew)"];
}

@end
