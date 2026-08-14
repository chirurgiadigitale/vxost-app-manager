//
//  XPExposure.m
//

#import "XPExposure.h"
#import "XPPaths.h"
#import "XPActions.h"
#import "XPTaskRunner.h"
#import "XPServiceMonitor.h"

/// L'indirizzo che vuol dire "solo questo Mac".
///
/// ⚠️ 127.0.0.1 e non il nome. Una Listen accetta un nome, ma lo risolve
/// all'avvio: se la risoluzione cambia, Apache si mette in ascolto altrove
/// senza dirlo. L'indirizzo non cambia mai.
static NSString *const XPLoopback = @"127.0.0.1";

@implementation XPExposure

#pragma mark - Lettura

+ (NSArray<NSString *> *)configurationFiles {
    return @[
        [XPPaths root:@"etc/httpd.conf"],
        [XPPaths root:@"etc/extra/httpd-ssl.conf"],
    ];
}

/// Le righe Listen vive di un file, come coppie (indirizzo, porta).
/// L'indirizzo è la stringa vuota quando la riga non ne ha uno.
+ (NSArray<NSArray<NSString *> *> *)listenLinesIn:(NSString *)configuration {
    NSMutableArray *found = [NSMutableArray array];
    for (NSString *raw in [configuration componentsSeparatedByString:@"\n"]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceCharacterSet]];
        // Le righe commentate non contano: una di quelle è l'esempio della
        // documentazione di Apache, e trattarla come una direttiva vera
        // significherebbe dire che la configurazione è incoerente.
        if ([line hasPrefix:@"#"]) continue;
        if (![line hasPrefix:@"Listen"]) continue;

        NSString *rest = [[line substringFromIndex:6] stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceCharacterSet]];
        if (rest.length == 0) continue;

        // "Listen 80 https" esiste: il protocollo dopo la porta si scarta.
        NSString *first = [rest componentsSeparatedByString:@" "].firstObject;

        // ⚠️ L'ultimo due punti, non il primo: un indirizzo IPv6 ne ha molti,
        // e "Listen [::]:443" spezzato sul primo darebbe una porta assurda.
        NSRange colon = [first rangeOfString:@":" options:NSBackwardsSearch];
        if (colon.location == NSNotFound) {
            [found addObject:@[@"", first]];
        } else {
            [found addObject:@[[first substringToIndex:colon.location],
                               [first substringFromIndex:colon.location + 1]]];
        }
    }
    return found;
}

+ (NSArray<NSNumber *> *)listenedPorts {
    NSMutableArray<NSNumber *> *ports = [NSMutableArray array];
    for (NSString *path in [self configurationFiles]) {
        NSString *text = [NSString stringWithContentsOfFile:path
                                                   encoding:NSUTF8StringEncoding
                                                      error:NULL];
        if (!text) continue;
        for (NSArray<NSString *> *entry in [self listenLinesIn:text]) {
            NSInteger port = entry[1].integerValue;
            if (port > 0 && ![ports containsObject:@(port)]) [ports addObject:@(port)];
        }
    }
    [ports sortUsingSelector:@selector(compare:)];
    return ports;
}

+ (XPExposureScope)currentScope {
    NSInteger closed = 0;
    NSInteger open = 0;

    for (NSString *path in [self configurationFiles]) {
        NSString *text = [NSString stringWithContentsOfFile:path
                                                   encoding:NSUTF8StringEncoding
                                                      error:NULL];
        if (!text) continue;
        for (NSArray<NSString *> *entry in [self listenLinesIn:text]) {
            NSString *address = entry[0];
            if (address.length == 0) {
                open++;                                     // tutte le interfacce
            } else if ([address isEqualToString:XPLoopback] ||
                       [address isEqualToString:@"localhost"]) {
                closed++;
            } else {
                // Un indirizzo specifico che non è il loopback: la macchina è
                // configurata a mano e non tocca a noi decidere cosa voleva.
                return XPExposureScopeMixed;
            }
        }
    }

    if (open == 0 && closed == 0) return XPExposureScopeMixed;   // niente da leggere
    if (open > 0 && closed > 0) return XPExposureScopeMixed;
    return open > 0 ? XPExposureScopeLocalNetwork : XPExposureScopeThisMac;
}

#pragma mark - Riscrittura

+ (NSString *)rewrite:(NSString *)configuration toScope:(XPExposureScope)scope {
    if (scope != XPExposureScopeThisMac && scope != XPExposureScopeLocalNetwork) {
        return nil;
    }

    NSMutableArray<NSString *> *out = [NSMutableArray array];
    BOOL changed = NO;

    for (NSString *raw in [configuration componentsSeparatedByString:@"\n"]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceCharacterSet]];
        if ([line hasPrefix:@"#"] || ![line hasPrefix:@"Listen"]) {
            [out addObject:raw];
            continue;
        }

        NSString *rest = [[line substringFromIndex:6] stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceCharacterSet]];
        NSArray<NSString *> *words = [rest componentsSeparatedByString:@" "];
        if (words.count == 0 || words[0].length == 0) {
            [out addObject:raw];
            continue;
        }

        NSString *first = words[0];
        NSRange colon = [first rangeOfString:@":" options:NSBackwardsSearch];
        NSString *port = colon.location == NSNotFound
                       ? first : [first substringFromIndex:colon.location + 1];

        NSString *replacement = scope == XPExposureScopeThisMac
            ? [NSString stringWithFormat:@"%@:%@", XPLoopback, port]
            : port;

        if ([first isEqualToString:replacement]) {
            [out addObject:raw];
            continue;
        }

        // Il resto della riga si conserva: "Listen 80 https" perde il "https"
        // se si riscrive la riga da zero, e con lui la dichiarazione del
        // protocollo.
        NSMutableArray *rebuilt = [@[@"Listen", replacement] mutableCopy];
        if (words.count > 1) {
            [rebuilt addObjectsFromArray:[words subarrayWithRange:
                                          NSMakeRange(1, words.count - 1)]];
        }
        [out addObject:[rebuilt componentsJoinedByString:@" "]];
        changed = YES;
    }

    return changed ? [out componentsJoinedByString:@"\n"] : nil;
}

#pragma mark - Applicazione

+ (void)applyScope:(XPExposureScope)scope completion:(void (^)(BOOL ok))completion {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSString *> *sources = [NSMutableArray array];
    NSMutableArray<NSString *> *staged = [NSMutableArray array];

    // Si prepara tutto prima di chiedere la password: se non c'è niente da
    // cambiare, non si chiede niente.
    for (NSString *path in [self configurationFiles]) {
        NSString *text = [NSString stringWithContentsOfFile:path
                                                   encoding:NSUTF8StringEncoding
                                                      error:NULL];
        if (!text) continue;
        NSString *rewritten = [self rewrite:text toScope:scope];
        if (!rewritten) continue;

        NSString *temporary = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"vxost-listen-%@.conf", [NSUUID UUID].UUIDString]];
        if (![rewritten writeToFile:temporary atomically:YES
                           encoding:NSUTF8StringEncoding error:NULL]) continue;
        [sources addObject:path];
        [staged addObject:temporary];
    }

    if (sources.count == 0) {
        [[XPActions shared] postMessage:NSLocalizedString(@"exposure.nochange", nil)
                                isError:NO];
        if (completion) completion(YES);
        return;
    }

    // La scrittura protetta e' una sola, e vive in XPActions: copia di
    // sicurezza, httpd -t, ripristino se fallisce, riavvio. Averne due
    // vorrebbe dire due reti di sicurezza da tenere allineate, e quella che si
    // dimentica e' sempre l'altra.
    NSMutableDictionary<NSString *, NSString *> *plan = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < sources.count; i++) plan[sources[i]] = staged[i];

    NSString *done = [NSString stringWithFormat:NSLocalizedString(@"exposure.done", nil),
                      [self nameForScope:scope]];

    [[XPActions shared] replaceConfiguration:plan
                                    progress:NSLocalizedString(@"exposure.applying", nil)
                                     success:done
                                  completion:^(BOOL ok) {
        for (NSString *path in staged) [fm removeItemAtPath:path error:NULL];
        if (completion) completion(ok);
    }];
}

#pragma mark - Nomi

+ (NSString *)nameForScope:(XPExposureScope)scope {
    switch (scope) {
        case XPExposureScopeThisMac:      return NSLocalizedString(@"exposure.thisMac", nil);
        case XPExposureScopeLocalNetwork: return NSLocalizedString(@"exposure.network", nil);
        case XPExposureScopeInternet:     return NSLocalizedString(@"exposure.internet", nil);
        case XPExposureScopeMixed:        return NSLocalizedString(@"exposure.mixed", nil);
    }
    return @"";
}

@end
