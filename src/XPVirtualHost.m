//
//  XPVirtualHost.m
//

#import "XPVirtualHost.h"
#import "XPPaths.h"

#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>

/// Verifica se qualcosa è in ascolto su 127.0.0.1:port.
///
/// Come per i servizi, si usa una connect() invece di lsof: da utente normale
/// lsof non vede i processi di root e daemon, quindi non vedrebbe httpd.
static BOOL VHostPortIsListening(uint16_t port, NSTimeInterval timeout) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return NO;

    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port   = htons(port);
    addr.sin_addr.s_addr = inet_addr("127.0.0.1");

    BOOL open = NO;
    int rc = connect(fd, (struct sockaddr *)&addr, sizeof(addr));

    if (rc == 0) {
        open = YES;
    } else if (errno == EINPROGRESS) {
        fd_set write_set;
        FD_ZERO(&write_set);
        FD_SET(fd, &write_set);

        struct timeval tv;
        tv.tv_sec  = (time_t)timeout;
        tv.tv_usec = (suseconds_t)((timeout - (NSTimeInterval)tv.tv_sec) * 1e6);

        if (select(fd + 1, NULL, &write_set, NULL, &tv) > 0) {
            int err = 0;
            socklen_t len = sizeof(err);
            if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) == 0 && err == 0) {
                open = YES;
            }
        }
    }

    close(fd);
    return open;
}

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
        if (serverName) current.serverName = serverName;
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
            if (VHostPortIsListening((uint16_t)host.port, 0.15)) {
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

/// Ricava un nome leggibile dal DocumentRoot.
+ (NSString *)projectNameForDocumentRoot:(NSString *)documentRoot {
    NSString *htdocs = [XPPaths htdocs];
    NSString *projects = [htdocs stringByAppendingPathComponent:@"progetti"];

    // Sotto progetti/ il percorso relativo è già il nome più chiaro.
    if ([documentRoot hasPrefix:projects]) {
        NSString *relative = [documentRoot substringFromIndex:projects.length];
        return [relative stringByTrimmingCharactersInSet:
                [NSCharacterSet characterSetWithCharactersInString:@"/"]];
    }

    if ([documentRoot isEqualToString:htdocs]) return @"htdocs";

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
    NSString *host = (self.serverName.length > 0) ? self.serverName : @"localhost";
    // ServerName è quasi sempre "localhost": ciò che distingue i progetti è la
    // porta, quindi l'URL si costruisce su quella.
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
