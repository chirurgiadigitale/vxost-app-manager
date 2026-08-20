//
//  XPGitLog.m
//

#import "XPGitLog.h"
#import "XPGitInfo.h"
#import "XPPaths.h"
#import "XPVirtualHost.h"

@implementation XPCommit
@end


/// Separatore fra i campi di una riga di log.
///
/// ⚠️ Non si usa un carattere stampabile. Con la tabulazione o la barra
/// verticale basta un messaggio di commit che le contiene e i campi si
/// spostano: il messaggio è testo libero scritto da chi committa, e prima o
/// poi qualcuno ci mette proprio quel carattere. \x1f è il separatore di unità
/// di ASCII, esiste per questo e in un messaggio non finisce.
static NSString *const XPFieldSeparator = @"\x1f";

@implementation XPGitLog

/// La radice del repository che contiene `path`, chiesta a git.
///
/// `rev-parse --show-toplevel` è la risposta autorevole: gestisce i .git che
/// sono file invece che cartelle (i submodule e i worktree), i link simbolici
/// e i repository montati altrove. Cercare a mano una cartella .git risalendo
/// i genitori sbaglia su tutti e tre i casi.
+ (NSString *)repositoryRootFor:(NSString *)path {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDirectory = NO;
    if (![fm fileExistsAtPath:path isDirectory:&isDirectory] || !isDirectory) return nil;

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/git"];
    task.arguments = @[@"-C", path, @"rev-parse", @"--show-toplevel"];
    NSPipe *out = [NSPipe pipe];
    task.standardOutput = out;
    task.standardError = [NSPipe pipe];
    if (![task launchAndReturnError:NULL]) return nil;

    NSData *data = [out.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    if (task.terminationStatus != 0) return nil;

    NSString *root = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
                      stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return root.length > 0 ? root : nil;
}


/// L'indirizzo web del remote `origin`, per costruire il link ai commit.
///
/// Il remote si legge da qui e non da XPGitInfo per la stessa ragione della
/// radice: quello non arriva ai repository fuori dal web root. La traduzione
/// da url di remote a indirizzo web resta sua, perché è la parte con più
/// varianti in circolazione ed è già provata.
+ (NSURL *)webURLForRepository:(NSString *)repository {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/git"];
    task.arguments = @[@"-C", repository, @"remote", @"get-url", @"origin"];
    NSPipe *out = [NSPipe pipe];
    task.standardOutput = out;
    task.standardError = [NSPipe pipe];
    if (![task launchAndReturnError:NULL]) return nil;

    NSData *data = [out.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    if (task.terminationStatus != 0) return nil;   // nessun remote: normale

    NSString *remote = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
                        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (remote.length == 0) return nil;
    return [XPGitInfo webURLFromRemote:remote];
}

+ (NSArray<XPCommit *> *)commitsForPath:(NSString *)path onDay:(NSDate *)day {
    if (!path || !day) return @[];

    // ⚠️ Non si passa da XPGitInfo per trovare il repository: quello si ferma
    // al web root di proposito, perché nella sezione Progetti risalire oltre
    // farebbe apparire il repository dello stack come se fosse del progetto.
    // Qui il percorso arriva già da un progetto, e il suo .git può stare dove
    // vuole — anche fuori, se il progetto è un link a una cartella altrove.
    // Chi decide dove fermarsi è git, che è l'unico a saperlo davvero.
    NSString *repository = [self repositoryRootFor:path];
    if (!repository) return @[];

    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSDate *from = [calendar startOfDayForDate:day];
    NSDate *to = [calendar dateByAddingUnit:NSCalendarUnitDay value:1 toDate:from options:0];

    NSDateFormatter *iso = [[NSDateFormatter alloc] init];
    iso.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    iso.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];

    NSString *format = [NSString stringWithFormat:@"%%h%@%%s%@%%an%@%%at",
                        XPFieldSeparator, XPFieldSeparator, XPFieldSeparator];

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/git"];
    task.arguments = @[
        @"-C", repository,
        @"log",
        // Sulla data di autore: --since e --until guardano quella di commit,
        // che un rebase riscrive.
        [NSString stringWithFormat:@"--since=%@", [iso stringFromDate:from]],
        [NSString stringWithFormat:@"--until=%@", [iso stringFromDate:to]],
        @"--date-order",
        @"--no-merges",              // un merge non è lavoro di quel giorno
        [NSString stringWithFormat:@"--format=%@", format],
    ];

    NSPipe *out = [NSPipe pipe];
    task.standardOutput = out;
    task.standardError = [NSPipe pipe];   // gli errori non vanno sul terminale

    NSError *error = nil;
    if (![task launchAndReturnError:&error]) return @[];

    NSData *data = [out.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    if (task.terminationStatus != 0) return @[];

    NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (output.length == 0) return @[];

    NSURL *webBase = [self webURLForRepository:repository];

    NSMutableArray<XPCommit *> *commits = [NSMutableArray array];
    for (NSString *line in [output componentsSeparatedByString:@"\n"]) {
        if (line.length == 0) continue;
        NSArray<NSString *> *fields = [line componentsSeparatedByString:XPFieldSeparator];
        if (fields.count < 4) continue;

        XPCommit *commit = [[XPCommit alloc] init];
        commit.shortHash = fields[0];
        commit.subject   = fields[1];
        commit.author    = fields[2];
        commit.date      = [NSDate dateWithTimeIntervalSince1970:fields[3].doubleValue];

        if (webBase && commit.shortHash.length > 0) {
            NSString *base = webBase.absoluteString;
            if ([base hasSuffix:@"/"]) base = [base substringToIndex:base.length - 1];
            commit.webURL = [NSURL URLWithString:
                             [NSString stringWithFormat:@"%@/commit/%@", base, commit.shortHash]];
        }
        [commits addObject:commit];
    }
    return commits;
}

+ (NSString *)pathForProjectKey:(NSString *)key {
    if (key.length == 0) return nil;

    // Le cartelle: la chiave porta il nome, il resto lo sa XPPaths.
    if ([key hasPrefix:@"folder:"]) {
        NSString *name = [key substringFromIndex:7];
        return [[XPPaths projectsRoot] stringByAppendingPathComponent:name];
    }

    // I virtual host: la porta è nella chiave, il DocumentRoot nel file di
    // configurazione. Si rilegge invece di tenerlo nella chiave, perché un
    // vhost può essere stato spostato dopo che le ore erano già registrate.
    if ([key hasPrefix:@"vhost:"]) {
        NSInteger port = [[key substringFromIndex:6] integerValue];
        for (XPVirtualHost *host in [XPVirtualHost allHosts]) {
            if (host.port == port) return host.documentRoot;
        }
        return nil;
    }

    // Le voci create a mano non hanno una cartella: sono nomi, non progetti
    // sul disco.
    return nil;
}

@end
