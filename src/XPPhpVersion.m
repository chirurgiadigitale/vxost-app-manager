//
//  XPPhpVersion.m
//

#import "XPPhpVersion.h"
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

@interface XPPhpVersion ()
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

- (NSString *)shortVersion {
    NSArray *parts = [self.version componentsSeparatedByString:@"."];
    if (parts.count < 2) return self.version;
    return [NSString stringWithFormat:@"%@.%@", parts[0], parts[1]];
}

- (NSString *)socketPath {
    if (self.isBundled) return nil;
    NSString *compact = [self.shortVersion stringByReplacingOccurrencesOfString:@"."
                                                                    withString:@""];
    return [XPPoolDirectory stringByAppendingPathComponent:
            [NSString stringWithFormat:@"vxost-php%@.sock", compact]];
}

- (BOOL)poolIsRunning {
    NSString *socket = self.socketPath;
    if (!socket) return YES;   // mod_php è dentro Apache: se Apache gira, c'è.
    NSDictionary *attributes = [[NSFileManager defaultManager]
                                attributesOfItemAtPath:socket error:NULL];
    return [attributes[NSFileType] isEqualToString:NSFileTypeSocket];
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

- (NSString *)description {
    return [NSString stringWithFormat:@"PHP %@%@", self.version,
            self.isBundled ? @" (in the box)" : @" (Homebrew)"];
}

@end
