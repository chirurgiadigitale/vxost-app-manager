//
//  XPPaths.m
//

#import "XPPaths.h"

/// Dove sta l'installazione.
///
/// Il percorso non e' fisso perche' non puo' esserlo durante la transizione: le
/// macchine che hanno gia' lo stack lo tengono nella vecchia cartella, le
/// installazioni nuove nella nuova, e per un periodo esistono entrambe. Un
/// percorso fisso rende l'app inservibile su meta' dei casi, con un errore che
/// dice soltanto che uno script non e' eseguibile.
///
/// Si sceglie al primo accesso, controllando quale contiene davvero lo script
/// di controllo. Nessuna configurazione da compilare, nessuna domanda
/// all'utente.
static NSString *XPDetectRoot(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *candidates = @[
        @"/Applications/VXOST/vxostfiles",
        @"/Applications/XAMPP/xamppfiles",
    ];
    for (NSString *base in candidates) {
        NSString *script = [base stringByAppendingPathComponent:
                            [base hasSuffix:@"vxostfiles"] ? @"vxost" : @"xampp"];
        if ([fm isExecutableFileAtPath:script]) {
            return base;
        }
    }
    // Nessuna delle due: si restituisce la nuova, cosi' il messaggio d'errore
    // nomina il percorso verso cui si sta andando.
    return candidates.firstObject;
}

static NSString *XPDetectControlScript(NSString *root) {
    NSString *name = [root hasSuffix:@"vxostfiles"] ? @"vxost" : @"xampp";
    return [root stringByAppendingPathComponent:name];
}



@implementation XPPaths

// Rilevata una volta sola: il percorso non cambia mentre l'app e' in esecuzione,
// e ricontrollare il filesystem a ogni chiamata costerebbe senza motivo.
+ (NSString *)installRoot {
    static NSString *root = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ root = XPDetectRoot(); });
    return root;
}

+ (NSString *)controlScript {
    static NSString *script = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ script = XPDetectControlScript([self installRoot]); });
    return script;
}

+ (NSString *)root:(NSString *)relative {
    return [[self installRoot] stringByAppendingPathComponent:relative];
}

+ (BOOL)installationIsValid {
    NSFileManager *fm = [NSFileManager defaultManager];
    return [fm isExecutableFileAtPath:[self controlScript]];
}

+ (NSString *)htdocs {
    // ⚠️ Il nome della radice web si rileva, non si scrive.
    //
    // Sta passando da htdocs a www, e durante il passaggio le due convivono su
    // macchine diverse. Un nome fisso qui rende l'app cieca su meta' delle
    // installazioni, ed e' esattamente l'errore gia' fatto con il percorso di
    // installazione in XPTaskRunner.
    static NSString *cached = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        for (NSString *name in @[@"www", @"htdocs"]) {
            NSString *candidate = [self root:name];
            BOOL isDirectory = NO;
            if ([fm fileExistsAtPath:candidate isDirectory:&isDirectory] && isDirectory) {
                cached = candidate;
                return;
            }
        }
        // Nessuna delle due: si restituisce quella verso cui si sta andando,
        // cosi' il messaggio d'errore nomina il percorso giusto.
        cached = [self root:@"www"];
    });
    return cached;
}

+ (NSString *)projectsRoot {
    // Stesso ragionamento della radice web: progetti e' diventata projects il
    // 13/08, ma chi non ha ancora migrato ha la vecchia.
    static NSString *cached = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        for (NSString *name in @[@"projects", @"progetti"]) {
            NSString *candidate = [[self htdocs] stringByAppendingPathComponent:name];
            BOOL isDirectory = NO;
            if ([fm fileExistsAtPath:candidate isDirectory:&isDirectory] && isDirectory) {
                cached = candidate;
                return;
            }
        }
        cached = [[self htdocs] stringByAppendingPathComponent:@"projects"];
    });
    return cached;
}

+ (NSArray<NSString *> *)projectFolders {
    // ⛔ Non si mette in cache: le cartelle nascono e spariscono mentre l'app
    // e' aperta, e un elenco congelato all'avvio direbbe che un progetto
    // creato cinque minuti fa non esiste.
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *content = [fm contentsOfDirectoryAtPath:[self projectsRoot] error:NULL];
    if (!content) return @[];

    NSMutableArray<NSString *> *folders = [NSMutableArray array];
    for (NSString *name in content) {
        if ([name hasPrefix:@"."]) continue;      // .DS_Store e simili
        BOOL isDirectory = NO;
        NSString *full = [[self projectsRoot] stringByAppendingPathComponent:name];
        if ([fm fileExistsAtPath:full isDirectory:&isDirectory] && isDirectory) {
            [folders addObject:name];
        }
    }
    [folders sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    return folders;
}

+ (NSString *)localHostname {
    // ⚠️ Niente dispatch_once (rilievo J). Il wizard aggiunge virtualhost a
    // /etc/hosts e un istante dopo chiede questo nome per aprire la
    // dashboard: con la cache "per sempre" leggeva ancora localhost, e su un
    // Mac con XAMPP apriva la dashboard di XAMPP. La cache vale finche'
    // /etc/hosts ha la stessa data di modifica: una stat per chiamata, non
    // una risoluzione DNS, e il file cambia solo quando qualcuno lo scrive.
    static NSString *name = nil;
    static NSDate *seen = nil;

    @synchronized ([XPPaths class]) {
        NSDictionary *attributes = [[NSFileManager defaultManager]
                                    attributesOfItemAtPath:@"/etc/hosts" error:NULL];
        NSDate *modified = attributes[NSFileModificationDate];
        if (name && seen && modified && [modified isEqualToDate:seen]) {
            return name;
        }

        NSString *found = @"localhost";

        // /etc/hosts e' leggibile da chiunque e dice la verita' senza costare
        // il timeout di una risoluzione DNS su un nome che non esiste.
        //
        // Si legge riga per riga invece che con una espressione regolare: il
        // primo tentativo la usava e sbagliava a causa delle sequenze di
        // escape, restituendo localhost su una macchina dove virtualhost c'era.
        NSString *hosts = [NSString stringWithContentsOfFile:@"/etc/hosts"
                                                    encoding:NSUTF8StringEncoding
                                                       error:NULL];
        NSCharacterSet *blank = [NSCharacterSet whitespaceCharacterSet];
        for (NSString *line in [hosts componentsSeparatedByString:@"\n"]) {
            // ⚠️ Un commento non e' una mappatura: "127.0.0.1 foo # virtualhost"
            // dice foo. Si taglia dal cancelletto in poi, ovunque stia.
            NSRange hash = [line rangeOfString:@"#"];
            NSString *clean = hash.location == NSNotFound
                            ? line : [line substringToIndex:hash.location];
            clean = [clean stringByTrimmingCharactersInSet:blank];
            if (clean.length == 0) continue;

            NSMutableArray<NSString *> *fields = [NSMutableArray array];
            for (NSString *field in [clean componentsSeparatedByCharactersInSet:blank]) {
                if (field.length > 0) [fields addObject:field];
            }
            // Il primo campo e' l'indirizzo: il nome conta solo se sta dopo.
            for (NSUInteger i = 1; i < fields.count; i++) {
                if ([fields[i] isEqualToString:@"virtualhost"]) {
                    found = @"virtualhost";
                    break;
                }
            }
            if ([found isEqualToString:@"virtualhost"]) break;
        }

        name = found;
        seen = modified;
        return name;
    }
}

+ (NSString *)vxostVersion {
    // Stessa fonte usata dallo script di controllo: `cat $VXOST_ROOT/lib/VERSION`.
    NSString *raw = [NSString stringWithContentsOfFile:[self root:@"lib/VERSION"]
                                              encoding:NSUTF8StringEncoding
                                                 error:NULL];
    if (!raw) return nil;

    NSString *version = [raw stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    // Il file riporta "8.2.4-0": il suffisso di build non interessa.
    NSRange dash = [version rangeOfString:@"-"];
    if (dash.location != NSNotFound) version = [version substringToIndex:dash.location];
    return version.length > 0 ? version : nil;
}

#pragma mark - Log

+ (NSArray<NSDictionary *> *)systemLogs {
    // Il .err di MySQL prende il nome dall'hostname della macchina.
    NSString *host = [[NSProcessInfo processInfo] hostName];
    NSString *mysqlErr = [self root:[NSString stringWithFormat:@"var/mysql/%@.err", host]];

    NSMutableArray *logs = [NSMutableArray array];
    [logs addObject:@{@"title": NSLocalizedString(@"log.system.apacheError", nil),  @"path": [self root:@"logs/error_log"]}];
    [logs addObject:@{@"title": NSLocalizedString(@"log.system.apacheAccess", nil), @"path": [self root:@"logs/access_log"]}];
    [logs addObject:@{@"title": NSLocalizedString(@"log.system.mysqlError", nil),   @"path": mysqlErr}];
    [logs addObject:@{@"title": @"ProFTPD",             @"path": [self root:@"var/proftpd.log"]}];

    // Tiene solo quelli che esistono davvero.
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *existing = [NSMutableArray array];
    for (NSDictionary *log in logs) {
        if ([fm fileExistsAtPath:log[@"path"]]) [existing addObject:log];
    }
    return existing;
}

+ (NSArray<NSDictionary *> *)projectLogs {
    NSString *logsDir = [self root:@"logs"];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *entries = [fm contentsOfDirectoryAtPath:logsDir error:NULL];
    if (!entries) return @[];

    NSMutableArray *result = [NSMutableArray array];
    // Ordine alfabetico, così il selettore resta stabile fra un refresh e l'altro.
    for (NSString *name in [entries sortedArrayUsingSelector:@selector(compare:)]) {
        BOOL isError  = [name hasSuffix:@"-error_log"];
        BOOL isAccess = [name hasSuffix:@"-access_log"];
        if (!isError && !isAccess) continue;

        NSString *host = [name stringByReplacingOccurrencesOfString:(isError ? @"-error_log" : @"-access_log")
                                                         withString:@""];
        NSString *title = [NSString stringWithFormat:@"%@, %@", host, isError ? @"error" : @"access"];
        [result addObject:@{@"title": title,
                            @"path": [logsDir stringByAppendingPathComponent:name]}];
    }
    return result;
}

#pragma mark - Config

+ (NSArray<NSDictionary *> *)configFiles {
    NSArray *candidates = @[
        @{@"title": @"httpd.conf",       @"path": [self root:@"etc/httpd.conf"]},
        @{@"title": @"httpd-vhosts.conf",@"path": [self root:@"etc/extra/httpd-vhosts.conf"]},
        @{@"title": @"httpd-ssl.conf",   @"path": [self root:@"etc/extra/httpd-ssl.conf"]},
        @{@"title": @"my.cnf",           @"path": [self root:@"etc/my.cnf"]},
        @{@"title": @"php.ini",          @"path": [self root:@"etc/php.ini"]},
        @{@"title": @"proftpd.conf",     @"path": [self root:@"etc/proftpd.conf"]},
    ];

    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *existing = [NSMutableArray array];
    for (NSDictionary *cfg in candidates) {
        if ([fm fileExistsAtPath:cfg[@"path"]]) [existing addObject:cfg];
    }
    return existing;
}

@end
