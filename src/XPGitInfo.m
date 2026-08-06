//
//  XPGitInfo.m
//

#import "XPGitInfo.h"
#import "XPPaths.h"

@implementation XPGitInfo

+ (instancetype)infoForPath:(NSString *)path {
    NSString *repository = [self repositoryRootForPath:path];
    if (!repository) return nil;

    XPGitInfo *info = [[XPGitInfo alloc] init];
    info.repositoryPath = repository;
    info.branch = [self branchInRepository:repository];

    NSString *remote = [self originURLInRepository:repository];
    if (remote) {
        info.shortName = [self shortNameFromRemote:remote];
        info.webURL = [self webURLFromRemote:remote];
        info.isGitHub = [remote containsString:@"github.com"];
    }

    // Senza remote né ramo non c'è niente da mostrare.
    return (info.shortName || info.branch) ? info : nil;
}

/// Risale i genitori finché trova un .git, senza uscire dal web root.
+ (NSString *)repositoryRootForPath:(NSString *)path {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *htdocs = [XPPaths htdocs];
    NSString *current = path;

    // Un vhost punta spesso a una sottocartella (public, dist, v4): il .git
    // sta più in alto. Il limite è htdocs, oltre il quale si finirebbe per
    // attribuire a un progetto il repository di un altro.
    while (current.length > 1 && [current hasPrefix:htdocs]) {
        BOOL isDirectory = NO;
        NSString *candidate = [current stringByAppendingPathComponent:@".git"];
        if ([fm fileExistsAtPath:candidate isDirectory:&isDirectory] && isDirectory) {
            return current;
        }
        NSString *parent = [current stringByDeletingLastPathComponent];
        if ([parent isEqualToString:current]) break;
        current = parent;
    }
    return nil;
}

/// Legge .git/HEAD, che contiene "ref: refs/heads/<ramo>".
+ (NSString *)branchInRepository:(NSString *)repository {
    NSString *head = [NSString stringWithContentsOfFile:
                      [repository stringByAppendingPathComponent:@".git/HEAD"]
                                               encoding:NSUTF8StringEncoding error:NULL];
    if (!head) return nil;

    NSString *trimmed = [head stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *prefix = @"ref: refs/heads/";
    if (![trimmed hasPrefix:prefix]) return nil;   // testa staccata: solo un hash
    return [trimmed substringFromIndex:prefix.length];
}

/// Estrae l'url di origin da .git/config.
+ (NSString *)originURLInRepository:(NSString *)repository {
    NSString *config = [NSString stringWithContentsOfFile:
                        [repository stringByAppendingPathComponent:@".git/config"]
                                                 encoding:NSUTF8StringEncoding error:NULL];
    if (!config) return nil;

    BOOL inOrigin = NO;
    for (NSString *rawLine in [config componentsSeparatedByString:@"\n"]) {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceCharacterSet]];

        if ([line hasPrefix:@"["]) {
            // Cambio di sezione: interessa solo [remote "origin"].
            inOrigin = [line hasPrefix:@"[remote \"origin\"]"];
            continue;
        }
        if (!inOrigin || ![line hasPrefix:@"url"]) continue;

        NSRange equals = [line rangeOfString:@"="];
        if (equals.location == NSNotFound) continue;
        return [[line substringFromIndex:equals.location + 1]
                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    }
    return nil;
}

/// Da un url di remote ricava "owner/repo".
///
/// Le due forme in circolazione sono https://host/owner/repo.git e
/// git@host:owner/repo.git: cambia solo come si arriva alla coda.
+ (NSString *)shortNameFromRemote:(NSString *)remote {
    NSString *path = remote;

    NSRange colon = [remote rangeOfString:@":"];
    if ([remote hasPrefix:@"git@"] && colon.location != NSNotFound) {
        path = [remote substringFromIndex:colon.location + 1];
    } else {
        NSURL *url = [NSURL URLWithString:remote];
        if (url.path) path = url.path;
    }

    if ([path hasSuffix:@".git"]) path = [path substringToIndex:path.length - 4];
    path = [path stringByTrimmingCharactersInSet:
            [NSCharacterSet characterSetWithCharactersInString:@"/"]];

    // Solo le ultime due componenti: owner e nome del repository.
    NSArray *parts = [path componentsSeparatedByString:@"/"];
    if (parts.count >= 2) {
        return [NSString stringWithFormat:@"%@/%@",
                parts[parts.count - 2], parts[parts.count - 1]];
    }
    return parts.count == 1 ? parts.firstObject : nil;
}

+ (NSURL *)webURLFromRemote:(NSString *)remote {
    if ([remote hasPrefix:@"http"]) {
        NSString *clean = [remote hasSuffix:@".git"]
            ? [remote substringToIndex:remote.length - 4] : remote;
        return [NSURL URLWithString:clean];
    }

    // Forma SSH: git@github.com:owner/repo.git diventa un indirizzo web.
    if ([remote hasPrefix:@"git@"]) {
        NSRange at = [remote rangeOfString:@"@"];
        NSRange colon = [remote rangeOfString:@":"];
        if (at.location == NSNotFound || colon.location == NSNotFound) return nil;

        NSString *host = [remote substringWithRange:
                          NSMakeRange(at.location + 1, colon.location - at.location - 1)];
        NSString *path = [remote substringFromIndex:colon.location + 1];
        if ([path hasSuffix:@".git"]) path = [path substringToIndex:path.length - 4];
        return [NSURL URLWithString:[NSString stringWithFormat:@"https://%@/%@", host, path]];
    }
    return nil;
}

@end
