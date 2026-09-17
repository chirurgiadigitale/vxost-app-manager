//
//  storagelatetest.m
//  Lo storico che sparisce mentre l'app e' aperta non deve far perdere uno stop.
//
//  Quindicesimo giro di Codex: il recupero dalla cartella precedente veniva
//  ritentato a OGNI salvataggio, perche' stava dentro storagePath. Con il file
//  corrente sparito e quello vecchio illeggibile, una pausa accendeva il blocco
//  dei salvataggi con due sessioni gia' aperte; lo stop successivo cambiava
//  solo la memoria, e al riavvio la sessione chiusa tornava aperta.
//
//  Il recupero si fa una volta, all'avvio. Dopo, in memoria c'e' gia' tutto
//  quello che c'era da recuperare, e scriverlo e' la cosa giusta.
//
#import <Cocoa/Cocoa.h>
#include <sys/stat.h>          // chmod
#import "XPTracker.h"
#import "XPTimeEntry.h"

static NSString *supportRoot;
NSArray<NSString *> *NSSearchPathForDirectoriesInDomains(NSSearchPathDirectory d, NSSearchPathDomainMask m, BOOL e) {
    return @[supportRoot];
}
static int sPassed = 0, sFailed = 0;
static void check(BOOL ok, NSString *what) {
    if (ok) { sPassed++; printf("  \033[32m✓\033[0m %s\n", what.UTF8String); }
    else    { sFailed++; printf("  \033[31m✗ %s\033[0m\n", what.UTF8String); }
}

static NSDictionary *openEntry(NSString *key, NSString *name) {
    XPTimeEntry *e = [XPTimeEntry new];
    e.projectKey = key; e.projectName = name; e.task = @"fixture";
    e.startDate = [NSDate dateWithTimeIntervalSinceNow:-3600];   // non un clic per sbaglio
    return [e dictionaryRepresentation];
}

int main(void) { @autoreleasepool {
    supportRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:
                   [NSString stringWithFormat:@"vxost-storagelatetest-%d", getpid()]];
    unsetenv("VXOST_TRACKER_STORE");
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *vecchia = [@[@"it.chirurgiadigitale.", @"xa", @"mpp"] componentsJoinedByString:@""];
    NSString *old = [[supportRoot stringByAppendingPathComponent:vecchia] stringByAppendingPathComponent:@"timesheet.json"];
    NSString *nuova = [supportRoot stringByAppendingPathComponent:@"it.equipedigitale.vxost/timesheet.json"];
    [fm createDirectoryAtPath:old.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL];
    [fm createDirectoryAtPath:nuova.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL];

    NSData *oldData = [@"{\"entries\":[],\"open\":[]}" dataUsingEncoding:NSUTF8StringEncoding];
    [oldData writeToFile:old atomically:YES];
    chmod(old.fileSystemRepresentation, 0);

    NSData *current = [NSJSONSerialization dataWithJSONObject:@{
        @"entries": @[], @"customProjects": @[],
        @"open": @[openEntry(@"custom:a", @"A"), openEntry(@"custom:b", @"B")]} options:0 error:NULL];
    [current writeToFile:nuova atomically:YES];

    printf("\n\033[1mLo storico sparisce con due sessioni aperte\033[0m\n");
    [NSApplication sharedApplication];
    XPTracker *t = [[XPTracker alloc] init];
    check(t.canRecord && t.currentEntries.count == 2, @"premessa: storico valido, due sessioni aperte");

    [fm removeItemAtPath:nuova error:NULL];           // sparisce durante l'esecuzione
    XPTimeEntry *a = [t currentEntryForProjectKey:@"custom:a"];
    XPTimeEntry *b = [t currentEntryForProjectKey:@"custom:b"];
    [t pauseEntry:a];
    check(t.canRecord, @"una pausa non accende il blocco dei salvataggi");
    [t stopEntry:b];
    check([fm fileExistsAtPath:nuova], @"lo storico viene riscritto");

    XPTracker *r = [[XPTracker alloc] init];
    check(r.currentEntries.count == 1, @"al riavvio resta aperta solo la sessione in pausa");
    check([r currentEntryForProjectKey:@"custom:b"] == nil, @"la sessione fermata non torna aperta");
    check([r entriesForDay:[NSDate date]].count == 1, @"la sessione fermata e' nella cronologia");

    chmod(old.fileSystemRepresentation, 0644);
    check([[NSData dataWithContentsOfFile:old] isEqual:oldData], @"lo storico precedente resta identico");

    [fm removeItemAtPath:supportRoot error:NULL];
    printf("\n\033[1m%d passati, %d falliti\033[0m\n\n", sPassed, sFailed);
    return sFailed ? 1 : 0;
}}
