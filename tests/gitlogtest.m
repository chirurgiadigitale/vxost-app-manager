//
//  gitlogtest.m
//  I commit di un giorno, letti da un repository costruito qui.
//
//  ⚠️ Il repository è finto e usa e getta, in /tmp: provare su quelli veri
//  legherebbe l'esito a cosa è stato committato oggi, e un test che passa o
//  fallisce secondo la giornata non dice niente.
//
//  Quello che si controlla è soprattutto una cosa: che un messaggio di commit
//  scritto da una persona non riesca a rompere il formato con cui lo si legge.
//  Il messaggio è testo libero, e prima o poi qualcuno ci mette dentro proprio
//  il carattere che si stava usando come separatore.
//

#import <Cocoa/Cocoa.h>
#import "XPGitLog.h"

static int sPassed = 0;
static int sFailed = 0;

static void check(BOOL condition, NSString *what) {
    if (condition) {
        sPassed++;
        printf("  \033[32m✓\033[0m %s\n", what.UTF8String);
    } else {
        sFailed++;
        printf("  \033[31m✗ %s\033[0m\n", what.UTF8String);
    }
}

static void section(NSString *title) {
    printf("\n\033[1m%s\033[0m\n", title.UTF8String);
}

/// Esegue un comando e aspetta che finisca, in silenzio.
static int run(NSString *directory, NSArray<NSString *> *arguments) {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/env"];
    task.arguments = arguments;
    task.currentDirectoryURL = [NSURL fileURLWithPath:directory];
    task.standardOutput = [NSPipe pipe];
    task.standardError = [NSPipe pipe];
    // Senza queste git rifiuta di committare su una macchina senza config.
    NSMutableDictionary *env = [[[NSProcessInfo processInfo] environment] mutableCopy];
    env[@"GIT_AUTHOR_NAME"] = @"Test";
    env[@"GIT_AUTHOR_EMAIL"] = @"test@example.com";
    env[@"GIT_COMMITTER_NAME"] = @"Test";
    env[@"GIT_COMMITTER_EMAIL"] = @"test@example.com";
    task.environment = env;
    if (![task launchAndReturnError:NULL]) return -1;
    [task waitUntilExit];
    return task.terminationStatus;
}

int main(void) { @autoreleasepool {
    printf("\n\033[1mI commit di un giorno\033[0m\n");

    NSString *repo = [NSTemporaryDirectory() stringByAppendingPathComponent:@"vxost-gitlogtest"];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:repo error:NULL];
    [fm createDirectoryAtPath:repo withIntermediateDirectories:YES attributes:nil error:NULL];

    run(repo, @[@"git", @"init", @"-q", @"-b", @"main"]);
    run(repo, @[@"git", @"remote", @"add", @"origin",
                @"https://github.com/chirurgiadigitale/finto.git"]);

    // Tre commit, di cui uno con un messaggio fatto apposta per rompere il
    // formato: tabulazione, barra verticale e un a capo annunciato.
    NSArray<NSString *> *messaggi = @[
        @"primo commit",
        @"secondo\tcon | caratteri \\n strani",
        @"terzo, con una virgola e \"virgolette\"",
    ];
    for (NSUInteger i = 0; i < messaggi.count; i++) {
        NSString *file = [repo stringByAppendingPathComponent:
                          [NSString stringWithFormat:@"file%lu.txt", (unsigned long)i]];
        [@"x" writeToFile:file atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        run(repo, @[@"git", @"add", @"-A"]);
        run(repo, @[@"git", @"commit", @"-q", @"-m", messaggi[i]]);
    }

    // ---------------------------------------------------------------------
    section(@"Leggere");

    NSArray<XPCommit *> *oggi = [XPGitLog commitsForPath:repo onDay:[NSDate date]];
    check(oggi.count == 3, @"trova i tre commit di oggi");

    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSDate *ieri = [calendar dateByAddingUnit:NSCalendarUnitDay value:-1
                                       toDate:[NSDate date] options:0];
    check([XPGitLog commitsForPath:repo onDay:ieri].count == 0,
          @"ieri non c'era niente, e infatti non trova niente");

    // ---------------------------------------------------------------------
    section(@"I campi restano al loro posto");

    BOOL tuttiInteri = YES;
    for (XPCommit *commit in oggi) {
        if (commit.shortHash.length < 4) tuttiInteri = NO;
        if (commit.subject.length == 0) tuttiInteri = NO;
        if (!commit.date) tuttiInteri = NO;
    }
    check(tuttiInteri, @"ogni commit ha hash, messaggio e data");

    BOOL trovatoStrano = NO;
    for (XPCommit *commit in oggi) {
        if ([commit.subject containsString:@"con | caratteri"]) trovatoStrano = YES;
    }
    check(trovatoStrano,
          @"un messaggio con tabulazioni e barre verticali arriva intero");

    BOOL autoreGiusto = YES;
    for (XPCommit *commit in oggi) {
        if (![commit.author isEqualToString:@"Test"]) autoreGiusto = NO;
    }
    check(autoreGiusto, @"l'autore e' quello che ha committato");

    check([oggi.firstObject.date compare:oggi.lastObject.date] != NSOrderedAscending,
          @"il piu' recente viene per primo");

    // ---------------------------------------------------------------------
    section(@"L'indirizzo del commit");

    XPCommit *primo = oggi.firstObject;
    check(primo.webURL != nil, @"il commit ha un indirizzo web");
    check(primo.webURL &&
          [primo.webURL.absoluteString containsString:@"/commit/"],
          @"che punta al commit, non alla radice del repository");
    check(primo.webURL &&
          [primo.webURL.absoluteString hasSuffix:primo.shortHash],
          @"e finisce con l'hash di questo commit");

    // ---------------------------------------------------------------------
    section(@"Quando non c'e' niente da leggere");

    NSString *vuota = [NSTemporaryDirectory() stringByAppendingPathComponent:@"vxost-nonrepo"];
    [fm removeItemAtPath:vuota error:NULL];
    [fm createDirectoryAtPath:vuota withIntermediateDirectories:YES attributes:nil error:NULL];
    check([XPGitLog commitsForPath:vuota onDay:[NSDate date]].count == 0,
          @"una cartella senza git non fa cadere niente");
    check([XPGitLog commitsForPath:@"/percorso/che/non/esiste" onDay:[NSDate date]].count == 0,
          @"un percorso inesistente nemmeno");
    check([XPGitLog commitsForPath:nil onDay:[NSDate date]].count == 0, @"ne' un nil");
    check([XPGitLog commitsForPath:repo onDay:nil].count == 0, @"ne' un giorno nullo");

    // ---------------------------------------------------------------------
    section(@"Dalla chiave del progetto al percorso");

    check([XPGitLog pathForProjectKey:@"custom:una voce a mano"] == nil,
          @"una voce creata a mano non ha una cartella");
    check([XPGitLog pathForProjectKey:@""] == nil, @"chiave vuota, nessun percorso");
    NSString *daCartella = [XPGitLog pathForProjectKey:@"folder:esempio"];
    check(daCartella && [daCartella hasSuffix:@"/esempio"],
          @"una chiave folder: porta alla cartella con quel nome");

    [fm removeItemAtPath:repo error:NULL];
    [fm removeItemAtPath:vuota error:NULL];

    printf("\n\033[1m%d passati, %d falliti\033[0m\n\n", sPassed, sFailed);
    return sFailed == 0 ? 0 : 1;
}}
