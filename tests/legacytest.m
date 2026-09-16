//
//  legacytest.m
//  Lo storico ore della cartella precedente viene recuperato, non perso.
//
//  Dalla prova del dodicesimo giro di Codex. Application Support e' dirottato
//  in una directory temporanea sostituendo NSSearchPathForDirectoriesInDomains,
//  e VXOST_TRACKER_STORE e' tolto: cosi' si esercita davvero il ramo che cerca
//  la cartella vecchia, senza toccare i dati veri.
//
#import <Cocoa/Cocoa.h>
#import "XPTracker.h"
#import "XPTimeEntry.h"
#import "XPTheme.h"

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
                   [NSString stringWithFormat:@"vxost-legacytest-%d", getpid()]];
    unsetenv("VXOST_TRACKER_STORE");
    NSFileManager *fm = [NSFileManager defaultManager];
    // Composto, come nell'app: il nome intero non compare nemmeno qui.
    NSString *vecchia = [@[@"it.chirurgiadigitale.", @"xa", @"mpp"] componentsJoinedByString:@""];
    NSString *old = [[supportRoot stringByAppendingPathComponent:vecchia] stringByAppendingPathComponent:@"timesheet.json"];
    [fm createDirectoryAtPath:old.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL];

    XPTimeEntry *e = [XPTimeEntry new];
    e.projectKey = @"custom:legacy"; e.projectName = @"Legacy"; e.task = @"fixture";
    e.startDate = [NSDate dateWithTimeIntervalSinceNow:-3600]; e.endDate = [NSDate date];
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"entries": @[[e dictionaryRepresentation]],
                                                              @"open": @[], @"customProjects": @[@"legacy"]}
                                                   options:0 error:NULL];
    [data writeToFile:old atomically:YES];

    printf("\n\033[1mStorico solo nella cartella precedente\033[0m\n");
    [NSApplication sharedApplication];
    XPTracker *t = [XPTracker shared];
    check([t entriesForDay:[NSDate date]].count == 1, @"la sessione vecchia viene caricata");
    check((NSInteger)[t totalForDay:[NSDate date]] >= 3599, @"e conta nel totale del giorno");
    [t addCustomProjectNamed:@"nuovo"];
    NSString *nuova = [supportRoot stringByAppendingPathComponent:@"it.equipedigitale.vxost/timesheet.json"];
    NSDictionary *saved = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:nuova] options:0 error:NULL];
    check([saved[@"entries"] count] == 1, @"dopo un salvataggio lo storico nuovo contiene la sessione vecchia");
    check([[NSData dataWithContentsOfFile:old] isEqual:data], @"la cartella vecchia resta identica");

    printf("\n\033[1mTema scelto nel dominio precedente\033[0m\n");
    // Un dominio FINTO, non quello vero: le preferenze di chi lancia il test
    // non si toccano. Il metodo e' lo stesso che l'app chiama con il dominio
    // del vecchio identificatore.
    NSString *dominio = [NSString stringWithFormat:@"it.equipedigitale.vxost.legacytest-%d", getpid()];
    NSUserDefaults *qui = [NSUserDefaults standardUserDefaults];
    [qui removeObjectForKey:@"ThemePreference"];
    CFPreferencesSetAppValue(CFSTR("ThemePreference"), (__bridge CFNumberRef)@(2), (__bridge CFStringRef)dominio);
    CFPreferencesAppSynchronize((__bridge CFStringRef)dominio);
    check([XPTheme importPreferenceFromDomain:dominio], @"la scelta del dominio precedente viene importata");
    check([XPTheme preference] == XPThemePreferenceLight, @"e il tema e' quello scelto allora (chiaro)");
    [qui setInteger:XPThemePreferenceAuto forKey:@"ThemePreference"];
    check(![XPTheme importPreferenceFromDomain:dominio] && [XPTheme preference] == XPThemePreferenceAuto,
          @"una scelta gia' fatta qui non viene sovrascritta");
    CFPreferencesSetAppValue(CFSTR("ThemePreference"), NULL, (__bridge CFStringRef)dominio);
    CFPreferencesAppSynchronize((__bridge CFStringRef)dominio);
    [qui removeObjectForKey:@"ThemePreference"];

    [fm removeItemAtPath:supportRoot error:NULL];
    printf("\n\033[1m%d passati, %d falliti\033[0m\n\n", sPassed, sFailed);
    return sFailed ? 1 : 0;
}}
