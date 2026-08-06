//
//  XPService.m
//

#import "XPService.h"
#import "XPPaths.h"
#import "XPTheme.h"
#import "XPTaskRunner.h"

#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>

#pragma mark - Probe TCP

/// Verifica se qualcosa è in ascolto su 127.0.0.1:port.
///
/// Serve un probe attivo perché `lsof` eseguito da utente normale non vede i
/// processi di root/daemon: httpd e proftpd risulterebbero senza porte.
/// Una connect() su loopback invece dice la verità senza alcun privilegio.
static BOOL PortIsListening(uint16_t port, NSTimeInterval timeout) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return NO;

    // Non bloccante, così il timeout è sotto il nostro controllo.
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
        open = YES;                       // connessa subito (caso tipico su loopback)
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

#pragma mark - Lettura porte dalla configurazione

/// Estrae i numeri di porta da un file di config, riga per riga, usando
/// la direttiva indicata (es. "Listen", "Port", "port").
static NSArray<NSNumber *> *PortsFromConfig(NSString *path, NSString *directive) {
    NSString *content = [NSString stringWithContentsOfFile:path
                                                  encoding:NSUTF8StringEncoding
                                                     error:NULL];
    if (!content) return @[];

    NSMutableArray<NSNumber *> *ports = [NSMutableArray array];
    NSString *pattern = [NSString stringWithFormat:@"(?im)^\\s*%@\\s*=?\\s*(?:[0-9a-fA-F.:\\[\\]]*:)?(\\d{1,5})\\b",
                         directive];
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern
                                                                       options:0
                                                                         error:NULL];
    if (!re) return @[];

    [re enumerateMatchesInString:content
                         options:0
                           range:NSMakeRange(0, content.length)
                      usingBlock:^(NSTextCheckingResult *m, NSMatchingFlags flags, BOOL *stop) {
        NSString *captured = [content substringWithRange:[m rangeAtIndex:1]];
        NSNumber *port = @(captured.integerValue);
        if (port.integerValue > 0 && port.integerValue <= 65535 && ![ports containsObject:port]) {
            [ports addObject:port];
        }
    }];
    return ports;
}

#pragma mark -

@interface XPService ()
@property (nonatomic, copy, readwrite) NSString *key;
@property (nonatomic, copy, readwrite) NSString *name;
@property (nonatomic, copy, readwrite) NSString *matchPattern;
@property (nonatomic, copy, readwrite) NSString *startAction;
@property (nonatomic, copy, readwrite) NSString *stopAction;
@property (nonatomic, copy, readwrite) NSString *reloadAction;
@property (nonatomic, strong, readwrite) NSColor *tint;
@end


@implementation XPService

+ (NSArray<XPService *> *)allServices {
    XPService *apache = [[XPService alloc] init];
    apache.key          = @"apache";
    apache.name         = @"Apache";
    apache.matchPattern = [XPPaths root:@"bin/httpd"];
    apache.startAction  = @"startapache";
    apache.stopAction   = @"stopapache";
    apache.reloadAction = @"reloadapache";

    XPService *mysql = [[XPService alloc] init];
    mysql.key          = @"mysql";
    mysql.name         = @"MySQL";
    mysql.matchPattern = [XPPaths root:@"sbin/mysqld"];
    mysql.startAction  = @"startmysql";
    mysql.stopAction   = @"stopmysql";
    mysql.reloadAction = @"reloadmysql";

    XPService *ftp = [[XPService alloc] init];
    ftp.key          = @"ftp";
    ftp.name         = @"ProFTPD";
    ftp.matchPattern = @"proftpd";
    ftp.startAction  = @"startftp";
    ftp.stopAction   = @"stopftp";
    ftp.reloadAction = @"reloadftp";

    // I tint si leggono a ogni accesso perché dipendono dal tema chiaro/scuro.
    return @[apache, mysql, ftp];
}

- (NSColor *)tint {
    if ([self.key isEqualToString:@"apache"]) return [XPTheme accent];
    if ([self.key isEqualToString:@"mysql"])  return [XPTheme cyan];
    return [XPTheme violet];
}

#pragma mark - Aggiornamento stato

- (void)refresh {
    [self refreshProcess];
    [self refreshPorts];
}

- (void)refreshProcess {
    // pgrep -f confronta l'intera riga di comando: distingue l'httpd di XAMPP
    // da un eventuale Apache di sistema, perché il pattern è il percorso pieno.
    XPTaskResult *result = [XPTaskRunner run:@"/usr/bin/pgrep" arguments:@[@"-f", self.matchPattern]];

    NSArray *lines = [result.output componentsSeparatedByCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    pid_t found = 0;
    for (NSString *line in lines) {
        if (line.length == 0) continue;
        pid_t candidate = (pid_t)line.intValue;
        // Il primo PID è il processo padre: è quello che ci interessa mostrare.
        if (candidate > 0) { found = candidate; break; }
    }

    self.pid = found;
    // Non sovrascrive lo stato "busy": una transizione in corso ha la precedenza
    // finché il comando non è tornato.
    if (self.state != XPServiceStateBusy) {
        self.state = (found > 0) ? XPServiceStateRunning : XPServiceStateStopped;
    }
}

- (void)refreshPorts {
    if (self.configuredPorts.count == 0) {
        self.configuredPorts = [self readConfiguredPorts];
    }

    NSMutableArray<NSNumber *> *listening = [NSMutableArray array];
    for (NSNumber *port in self.configuredPorts) {
        if (PortIsListening((uint16_t)port.unsignedShortValue, 0.15)) {
            [listening addObject:port];
        }
    }
    self.listeningPorts = listening;
}

- (NSArray<NSNumber *> *)readConfiguredPorts {
    NSMutableArray<NSNumber *> *ports = [NSMutableArray array];

    if ([self.key isEqualToString:@"apache"]) {
        [ports addObjectsFromArray:PortsFromConfig([XPPaths root:@"etc/httpd.conf"], @"Listen")];
        [ports addObjectsFromArray:PortsFromConfig([XPPaths root:@"etc/extra/httpd-ssl.conf"], @"Listen")];
        if (ports.count == 0) [ports addObjectsFromArray:@[@80, @443]];
    } else if ([self.key isEqualToString:@"mysql"]) {
        [ports addObjectsFromArray:PortsFromConfig([XPPaths root:@"etc/my.cnf"], @"port")];
        if (ports.count == 0) [ports addObject:@3306];
    } else {
        [ports addObjectsFromArray:PortsFromConfig([XPPaths root:@"etc/proftpd.conf"], @"Port")];
        if (ports.count == 0) [ports addObject:@21];
    }

    // Deduplica mantenendo l'ordine di lettura.
    NSMutableArray<NSNumber *> *unique = [NSMutableArray array];
    for (NSNumber *p in ports) {
        if (![unique containsObject:p]) [unique addObject:p];
    }
    return unique;
}

#pragma mark - Presentazione

- (NSString *)portsDescription {
    NSArray<NSNumber *> *ports = (self.state == XPServiceStateRunning && self.listeningPorts.count > 0)
                                 ? self.listeningPorts
                                 : self.configuredPorts;
    if (ports.count == 0) return @"—";

    // Con i vhost dei progetti Apache può ascoltare su parecchie porte: se ne
    // mostrano al massimo tre, il resto va nel conteggio per non sfondare la
    // riga. L'elenco completo resta nel tooltip.
    static const NSUInteger maxShown = 3;
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSNumber *p in ports) {
        if (parts.count == maxShown) break;
        [parts addObject:p.stringValue];
    }

    NSString *text = [parts componentsJoinedByString:@", "];
    if (ports.count > maxShown) {
        text = [text stringByAppendingFormat:@" +%lu", (unsigned long)(ports.count - maxShown)];
    }
    return text;
}

- (NSString *)allPortsDescription {
    NSArray<NSNumber *> *ports = (self.state == XPServiceStateRunning && self.listeningPorts.count > 0)
                                 ? self.listeningPorts
                                 : self.configuredPorts;
    if (ports.count == 0) return NSLocalizedString(@"service.ports.none", nil);

    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSNumber *p in ports) [parts addObject:p.stringValue];
    return [NSString stringWithFormat:NSLocalizedString(@"service.ports.tooltip", nil),
            self.name, [parts componentsJoinedByString:@", "]];
}

@end
