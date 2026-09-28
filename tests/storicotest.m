//
//  storicotest.m
//  Lo storico delle ore davanti a un file rotto e a un disco che rifiuta.
//
//  Revisione del 28/09/2026, tre difetti nello stesso punto:
//    - un JSON valido ma con la forma sbagliata ({"entries":"x"}) faceva
//      cadere l'app a ogni avvio;
//    - un JSON rotto veniva messo da parte in silenzio: la cronologia
//      ripartiva vuota e nessuno sapeva dove fossero finite le ore;
//    - un salvataggio fallito a sessione avviata lasciava vedere ore che alla
//      chiusura sparivano, con un NSLog come unico segnale.
//
#import <Cocoa/Cocoa.h>
#include <sys/stat.h>          // chmod
#import "XPTracker.h"
#import "XPTimeEntry.h"

static int sPassed = 0, sFailed = 0;
static void check(BOOL ok, NSString *what) {
    if (ok) { sPassed++; printf("  \033[32m✓\033[0m %s\n", what.UTF8String); }
    else    { sFailed++; printf("  \033[31m✗ %s\033[0m\n", what.UTF8String); }
}

static NSArray<NSString *> *messiDaParte(NSString *path) {
    NSString *dir = path.stringByDeletingLastPathComponent;
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *n in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:NULL]) {
        if ([n hasPrefix:@"timesheet.json.corrupt-"]) [out addObject:[dir stringByAppendingPathComponent:n]];
    }
    return out;
}

static XPTrackableProject *progetto(void) {
    XPTrackableProject *p = [XPTrackableProject new];
    p.key = @"custom:prova"; p.name = @"prova"; p.isCustom = YES;
    return p;
}

int main(void) { @autoreleasepool {
    [NSApplication sharedApplication];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:
                     [NSString stringWithFormat:@"vxost-storicotest-%d", getpid()]];
    NSString *path = [dir stringByAppendingPathComponent:@"timesheet.json"];
    setenv("VXOST_TRACKER_STORE", path.fileSystemRepresentation, 1);

    for (NSString *contenuto in @[@"{\"entries\":\"x\"}", @"{\"open\":{\"a\":1}}",
                                  @"{\"customProjects\":7}", @"{\"entries\":[",
                                  // Un livello piu' giu': un campo di testo che non e' testo
                                  // faceva cadere l'app al primo calcolo dei totali.
                                  @"{\"entries\":[{\"start\":1000,\"end\":2000,\"projectKey\":5}]}",
                                  @"{\"open\":[{\"start\":1000,\"task\":[1]}]}"]) {
        printf("\n\033[1mStorico %s\033[0m\n", contenuto.UTF8String);
        [fm removeItemAtPath:dir error:NULL];
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
        NSData *originale = [contenuto dataUsingEncoding:NSUTF8StringEncoding];
        [originale writeToFile:path atomically:YES];

        XPTracker *t = nil;
        @try { t = [[XPTracker alloc] init]; } @catch (NSException *e) { t = nil; }
        check(t != nil, @"l'app parte, non cade");
        NSArray *parte = messiDaParte(path);
        check(parte.count == 1, @"il file e' messo da parte, non sovrascritto");
        check(parte.count == 1 && [[NSData dataWithContentsOfFile:parte.firstObject] isEqual:originale],
              @"il file messo da parte e' identico all'originale");
        check(t.storageNotice == XPStorageNoticeSetAside, @"il tracker lo annuncia");
        check(parte.count == 1 && [t.storageNoticePath isEqualToString:parte.firstObject],
              @"e dice dove sta il file");
        check(t.canRecord, @"si puo' continuare a registrare");
        BOOL cade = NO;
        @try { [t totalForProjectKey:@"custom:prova" onDay:[NSDate dateWithTimeIntervalSince1970:1500]]; }
        @catch (NSException *e) { cade = YES; }
        check(!cade, @"i totali si calcolano senza cadere");
    }

    printf("\n\033[1mUn null dove ci sarebbe un elenco vuoto\033[0m\n");
    [fm removeItemAtPath:dir error:NULL];
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    [@"{\"entries\":[{\"start\":1000,\"end\":2000,\"projectKey\":\"custom:prova\",\"projectName\":\"prova\"}],\"open\":null}"
        writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    XPTracker *n = [[XPTracker alloc] init];
    check(n.storageNotice == XPStorageNoticeNone, @"non e' un file rotto: niente avviso");
    check(messiDaParte(path).count == 0, @"e non viene messo da parte");
    check([n entriesForDay:[NSDate dateWithTimeIntervalSince1970:1500]].count == 1, @"la sessione c'e'");

    printf("\n\033[1mIl salvataggio fallisce a sessione avviata\033[0m\n");
    [fm removeItemAtPath:dir error:NULL];
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    XPTracker *t = [[XPTracker alloc] init];
    check(t.storageNotice == XPStorageNoticeNone, @"premessa: nessun avviso");

    __block NSInteger avvisi = 0;
    id obs = [[NSNotificationCenter defaultCenter] addObserverForName:XPTrackerStorageNoticeNotification
                                                               object:t queue:nil
                                                           usingBlock:^(NSNotification *n) { avvisi++; }];
    chmod(dir.fileSystemRepresentation, 0500);          // la cartella non accetta scritture
    [t startProject:progetto() task:@"prima"];
    check(t.storageNotice == XPStorageNoticeSaveFailed, @"il salvataggio fallito e' annunciato");
    check([t.storageNoticePath isEqualToString:path], @"con il percorso del file");
    check(avvisi == 1, @"con una notifica");
    [t pauseEntry:[t currentEntryForProjectKey:@"custom:prova"]];
    check(avvisi == 1, @"una volta sola, non a ogni tentativo");
    // Alla chiusura l'app chiede un ultimo salvataggio: deve sapere com'e' andato.
    check(![t saveNow], @"saveNow dice che il salvataggio non e' riuscito");

    chmod(dir.fileSystemRepresentation, 0755);          // il disco torna a posto
    [t resumeEntry:[t currentEntryForProjectKey:@"custom:prova"]];
    check(t.storageNotice == XPStorageNoticeNone, @"al primo salvataggio riuscito l'avviso sparisce");
    check([t saveNow], @"e saveNow, adesso, dice che e' riuscito");
    check([fm fileExistsAtPath:path], @"e le ore sono sul disco");
    XPTracker *r = [[XPTracker alloc] init];
    check([r currentEntryForProjectKey:@"custom:prova"] != nil, @"al riavvio la sessione c'e'");

    [[NSNotificationCenter defaultCenter] removeObserver:obs];
    chmod(dir.fileSystemRepresentation, 0755);
    [fm removeItemAtPath:dir error:NULL];
    printf("\n\033[1m%d passati, %d falliti\033[0m\n\n", sPassed, sFailed);
    return sFailed ? 1 : 0;
}}
