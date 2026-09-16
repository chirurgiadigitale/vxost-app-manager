//
//  legacyfailtest.m
//  Se il recupero dello storico precedente fallisce, non si salva niente.
//
//  Tredicesimo giro di Codex: con la copia fallita, load partiva con lo
//  storico vuoto e il primo salvataggio creava un file nuovo SENZA le ore
//  precedenti; da li' in poi il recupero non ripartiva, perche' il file nuovo
//  esisteva. Qui la copia fallisce perche' il file vecchio non e' leggibile.
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

int main(void) { @autoreleasepool {
    supportRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:
                   [NSString stringWithFormat:@"vxost-legacyfailtest-%d", getpid()]];
    unsetenv("VXOST_TRACKER_STORE");
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *vecchia = [@[@"it.chirurgiadigitale.", @"xa", @"mpp"] componentsJoinedByString:@""];
    NSString *old = [[supportRoot stringByAppendingPathComponent:vecchia] stringByAppendingPathComponent:@"timesheet.json"];
    NSString *nuova = [supportRoot stringByAppendingPathComponent:@"it.equipedigitale.vxost/timesheet.json"];
    [fm createDirectoryAtPath:old.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL];

    XPTimeEntry *e = [XPTimeEntry new];
    e.projectKey = @"custom:legacy"; e.projectName = @"Legacy"; e.task = @"fixture";
    e.startDate = [NSDate dateWithTimeIntervalSinceNow:-3600]; e.endDate = [NSDate date];
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"entries": @[[e dictionaryRepresentation]],
                                                              @"open": @[], @"customProjects": @[]}
                                                   options:0 error:NULL];
    [data writeToFile:old atomically:YES];
    chmod(old.fileSystemRepresentation, 0);          // la copia fallira'

    printf("\n\033[1mCopia dello storico precedente che fallisce\033[0m\n");
    [NSApplication sharedApplication];
    XPTracker *t = [XPTracker shared];
    check([t entriesForDay:[NSDate date]].count == 0, @"premessa: la sessione vecchia non e' stata caricata");
    // Anche con il file di nuovo leggibile PRIMA del salvataggio: e' il caso in
    // cui Codex ha visto lo storico nuovo scritto vuoto.
    chmod(old.fileSystemRepresentation, 0644);
    [t addCustomProjectNamed:@"nuovo"];
    check(![fm fileExistsAtPath:nuova] ||
          [[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:nuova] options:0 error:NULL][@"entries"] count] > 0,
          @"nessuno storico nuovo scritto senza le ore precedenti");
    check([[NSData dataWithContentsOfFile:old] isEqual:data], @"lo storico precedente resta identico");

    [fm removeItemAtPath:supportRoot error:NULL];
    printf("\n\033[1m%d passati, %d falliti\033[0m\n\n", sPassed, sFailed);
    return sFailed ? 1 : 0;
}}
