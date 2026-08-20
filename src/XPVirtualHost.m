//
//  XPVirtualHost.m
//

#import "XPVirtualHost.h"
#import "XPPaths.h"
#import "XPService.h"

// Il probe TCP sta in XPService: ne esisteva una copia identica anche qui, e
// due copie della stessa funzione sono due posti dove correggere lo stesso bug.

/// Toglie il commento iniziale da una riga, se c'è.
static NSString *Uncomment(NSString *line) {
    NSString *trimmed = [line stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceCharacterSet]];
    while ([trimmed hasPrefix:@"#"]) {
        trimmed = [[trimmed substringFromIndex:1]
                   stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    }
    return trimmed;
}

/// Estrae il valore di una direttiva, togliendo eventuali virgolette.
static NSString *DirectiveValue(NSString *line, NSString *directive) {
    NSString *clean = Uncomment(line);
    if (![[clean lowercaseString] hasPrefix:[directive lowercaseString]]) return nil;

    NSString *value = [[clean substringFromIndex:directive.length]
                       stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if ([value hasPrefix:@"\""] && [value hasSuffix:@"\""] && value.length > 1) {
        value = [value substringWithRange:NSMakeRange(1, value.length - 2)];
    }
    return value.length > 0 ? value : nil;
}


@implementation XPVirtualHost

+ (NSArray<XPVirtualHost *> *)allHosts {
    return [self hostsFromFile:[XPPaths root:@"etc/extra/httpd-vhosts.conf"]
                    probePorts:YES];
}

+ (NSArray<XPVirtualHost *> *)hostsFromFile:(NSString *)path probePorts:(BOOL)probe {
    NSString *content = [NSString stringWithContentsOfFile:path
                                                  encoding:NSUTF8StringEncoding
                                                     error:NULL];
    if (!content) return @[];

    NSMutableArray<XPVirtualHost *> *hosts = [NSMutableArray array];
    XPVirtualHost *current = nil;
    BOOL currentIsCommented = NO;

    // Si scorre riga per riga invece di usare una regex sull'intero file: i
    // blocchi commentati vanno riconosciuti, non saltati, perché è proprio la
    // porta "sparita" che l'utente vuole spiegata.
    for (NSString *rawLine in [content componentsSeparatedByString:@"\n"]) {
        NSString *line = Uncomment(rawLine);
        BOOL isCommented = [[rawLine stringByTrimmingCharactersInSet:
                             [NSCharacterSet whitespaceCharacterSet]] hasPrefix:@"#"];

        if ([[line lowercaseString] hasPrefix:@"<virtualhost"]) {
            // Apertura del blocco: la porta sta dopo i due punti.
            NSRange colon = [line rangeOfString:@":"];
            NSRange close = [line rangeOfString:@">"];
            if (colon.location != NSNotFound && close.location != NSNotFound &&
                close.location > colon.location) {
                NSString *portText = [line substringWithRange:
                                      NSMakeRange(colon.location + 1,
                                                  close.location - colon.location - 1)];
                current = [[XPVirtualHost alloc] init];
                current.port = portText.integerValue;
                currentIsCommented = isCommented;
            }
            continue;
        }

        if ([[line lowercaseString] hasPrefix:@"</virtualhost"]) {
            if (current && current.port > 0 && current.documentRoot) {
                current.state = currentIsCommented ? XPVHostStateDisabled : XPVHostStateStopped;
                [hosts addObject:current];
            }
            current = nil;
            continue;
        }

        if (!current) continue;

        NSString *docRoot = DirectiveValue(line, @"DocumentRoot");
        if (docRoot) {
            current.documentRoot = docRoot;
            current.name = [self projectNameForDocumentRoot:docRoot];
            continue;
        }

        NSString *serverName = DirectiveValue(line, @"ServerName");
        if (serverName) {
            current.serverName = serverName;
            continue;
        }

        // SetHandler "proxy:unix:/tmp/vxost-php85.sock|fcgi://localhost"
        //
        // Si cerca la sottostringa invece di analizzare la direttiva: sta
        // dentro un <FilesMatch>, quindi non è in cima al blocco, e la
        // funzione che legge le direttive vuole la riga che comincia con il
        // nome. Qui interessa solo il percorso fra "unix:" e la barra.
        NSRange unix = [line rangeOfString:@"proxy:unix:"];
        if (unix.location != NSNotFound) {
            NSString *rest = [line substringFromIndex:NSMaxRange(unix)];
            NSRange pipe = [rest rangeOfString:@"|"];
            if (pipe.location != NSNotFound) {
                current.phpSocket = [rest substringToIndex:pipe.location];
            }
        }
    }

    // Il repository si cerca una volta sola per host: sono due file di testo
    // per progetto, non vale la pena rifarlo a ogni ridisegno.
    for (XPVirtualHost *host in hosts) {
        host.git = [XPGitInfo infoForPath:host.documentRoot];
    }

    // Lo stato reale delle porte si verifica solo per i blocchi attivi: una
    // porta commentata resta "disattivata" anche se qualcos'altro la occupa.
    if (probe) {
        for (XPVirtualHost *host in hosts) {
            if (host.state == XPVHostStateDisabled) continue;
            if ([XPService portIsListening:(uint16_t)host.port timeout:0.15]) {
                host.state = XPVHostStateListening;
            }
        }
    }

    [hosts sortUsingComparator:^NSComparisonResult(XPVirtualHost *a, XPVirtualHost *b) {
        if (a.port == b.port) return NSOrderedSame;
        return a.port < b.port ? NSOrderedAscending : NSOrderedDescending;
    }];
    return hosts;
}

+ (NSString *)configuration:(NSString *)configuration
                 settingPhp:(NSString *)directive
                    forPort:(NSInteger)port {

    NSMutableArray<NSString *> *out = [NSMutableArray array];
    NSMutableArray<NSString *> *pendingComments = [NSMutableArray array];
    NSMutableArray<NSString *> *filesMatch = nil;
    BOOL inTarget = NO;
    BOOL changed = NO;

    NSString *wanted = directive ?: @"";

    for (NSString *raw in [configuration componentsSeparatedByString:@"\n"]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceCharacterSet]];
        NSString *lower = [line lowercaseString];

        // Dentro un <FilesMatch> si accumula: se contiene un socket php-fpm il
        // blocco intero sparisce, altrimenti torna dov'era. Deciderlo riga per
        // riga cancellerebbe anche i FilesMatch che non c'entrano niente.
        if (filesMatch) {
            [filesMatch addObject:raw];
            if ([lower hasPrefix:@"</filesmatch"]) {
                BOOL isPhpPool = NO;
                for (NSString *buffered in filesMatch) {
                    if ([buffered containsString:@"proxy:unix:"]) { isPhpPool = YES; break; }
                }
                if (isPhpPool) {
                    changed = YES;              // il vecchio blocco se ne va
                    [pendingComments removeAllObjects];
                } else {
                    [out addObjectsFromArray:pendingComments];
                    [pendingComments removeAllObjects];
                    [out addObjectsFromArray:filesMatch];
                }
                filesMatch = nil;
            }
            continue;
        }

        if (inTarget && [lower hasPrefix:@"<filesmatch"]) {
            filesMatch = [@[raw] mutableCopy];
            continue;
        }

        // I commenti in attesa: quelli che il blocco PHP si porta dietro se ne
        // vanno con lui, gli altri restano. Finché non si sa cosa segue, si
        // tengono da parte.
        if (inTarget && [line hasPrefix:@"#"]) {
            [pendingComments addObject:raw];
            continue;
        }
        [out addObjectsFromArray:pendingComments];
        [pendingComments removeAllObjects];

        if ([lower hasPrefix:@"<virtualhost"]) {
            // ⚠️ Solo i blocchi vivi. Il confronto sul raw e non sul trimmed
            // ripulito: un blocco commentato comincia con # e qui non deve
            // entrare.
            NSRange colon = [line rangeOfString:@":"];
            NSRange close = [line rangeOfString:@">"];
            inTarget = NO;
            if (colon.location != NSNotFound && close.location != NSNotFound &&
                close.location > colon.location) {
                NSString *text = [line substringWithRange:
                                  NSMakeRange(colon.location + 1,
                                              close.location - colon.location - 1)];
                inTarget = text.integerValue == port;
            }
            [out addObject:raw];
            continue;
        }

        if (inTarget && [lower hasPrefix:@"</virtualhost"]) {
            if (wanted.length > 0) {
                // La direttiva finisce già con un a capo: si divide e si
                // aggiungono le righe, o nel file resterebbe una riga vuota.
                for (NSString *piece in [wanted componentsSeparatedByString:@"\n"]) {
                    if (piece.length > 0) [out addObject:piece];
                }
                changed = YES;
            }
            inTarget = NO;
            [out addObject:raw];
            continue;
        }

        [out addObject:raw];
    }
    [out addObjectsFromArray:pendingComments];
    if (filesMatch) [out addObjectsFromArray:filesMatch];   // blocco mai chiuso

    return changed ? [out componentsJoinedByString:@"\n"] : nil;
}

/// Ricava un nome leggibile dal DocumentRoot.
+ (NSString *)projectNameForDocumentRoot:(NSString *)documentRoot {
    // ⚠️ I percorsi si confrontano risolti, non come stringhe.
    //
    // Dopo la migrazione i virtual host dicono ancora /Applications/XAMPP/...,
    // che e' un symlink verso /Applications/VXOST/..., mentre XPPaths
    // restituisce quello nuovo. Due stringhe diverse per la stessa cartella:
    // il confronto falliva e ogni progetto finiva chiamato con l'ultima
    // componente del percorso, cioe' "public" per meta' di loro.
    documentRoot = [documentRoot stringByResolvingSymlinksInPath];
    NSString *htdocs = [[XPPaths htdocs] stringByResolvingSymlinksInPath];
    // ⚠️ La cartella si chiama projects dal 13/08. Questa riga diceva ancora
    // progetti, quindi il nome del progetto veniva ricavato con la regola
    // sbagliata e usciva con "projects/" davanti.
    NSString *projects = [htdocs stringByAppendingPathComponent:@"projects"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:projects]) {
        projects = [htdocs stringByAppendingPathComponent:@"progetti"];
    }

    // Sotto projects/ il percorso relativo è già il nome più chiaro.
    if ([documentRoot hasPrefix:projects]) {
        NSString *relative = [documentRoot substringFromIndex:projects.length];
        return [relative stringByTrimmingCharactersInSet:
                [NSCharacterSet characterSetWithCharactersInString:@"/"]];
    }

    // Il nome vero della cartella, non la parola scritta a mano: durante il
    // passaggio a www un'etichetta fissa direbbe una cosa e il Finder un'altra.
    if ([documentRoot isEqualToString:htdocs]) return [htdocs lastPathComponent];

    if ([documentRoot hasPrefix:htdocs]) {
        NSString *relative = [documentRoot substringFromIndex:htdocs.length];
        return [relative stringByTrimmingCharactersInSet:
                [NSCharacterSet characterSetWithCharactersInString:@"/"]];
    }

    // Percorso fuori dal web root: resta l'ultima componente.
    return documentRoot.lastPathComponent;
}

#pragma mark - Presentazione

- (NSURL *)url {
    NSString *host = (self.serverName.length > 0) ? self.serverName : [XPPaths localHostname];
    // Dal 16/08 ogni ServerName è "virtualhost": ciò che distingue i progetti
    // è la porta, quindi l'URL si costruisce su quella.
    return [NSURL URLWithString:[NSString stringWithFormat:@"http://%@:%ld/",
                                 host, (long)self.port]];
}

- (NSString *)stateDescription {
    switch (self.state) {
        case XPVHostStateListening: return NSLocalizedString(@"vhost.listening", nil);
        case XPVHostStateDisabled:  return NSLocalizedString(@"vhost.disabled", nil);
        default:                    return NSLocalizedString(@"vhost.notResponding", nil);
    }
}

@end
