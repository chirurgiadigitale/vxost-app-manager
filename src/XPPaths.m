//
//  XPPaths.m
//

#import "XPPaths.h"

NSString *const XPRoot = @"/Applications/XAMPP/xamppfiles";
NSString *const XPControlScript = @"/Applications/XAMPP/xamppfiles/xampp";

@implementation XPPaths

+ (NSString *)root:(NSString *)relative {
    return [XPRoot stringByAppendingPathComponent:relative];
}

+ (BOOL)installationIsValid {
    NSFileManager *fm = [NSFileManager defaultManager];
    return [fm isExecutableFileAtPath:XPControlScript];
}

+ (NSString *)htdocs {
    return [self root:@"htdocs"];
}

#pragma mark - Log

+ (NSArray<NSDictionary *> *)systemLogs {
    // Il .err di MySQL prende il nome dall'hostname della macchina.
    NSString *host = [[NSProcessInfo processInfo] hostName];
    NSString *mysqlErr = [self root:[NSString stringWithFormat:@"var/mysql/%@.err", host]];

    NSMutableArray *logs = [NSMutableArray array];
    [logs addObject:@{@"title": @"Apache — error_log",  @"path": [self root:@"logs/error_log"]}];
    [logs addObject:@{@"title": @"Apache — access_log", @"path": [self root:@"logs/access_log"]}];
    [logs addObject:@{@"title": @"MySQL — error",       @"path": mysqlErr}];
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
        NSString *title = [NSString stringWithFormat:@"%@ — %@", host, isError ? @"error" : @"access"];
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
