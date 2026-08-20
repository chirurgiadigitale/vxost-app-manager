//
//  trackertest.m
//  Le correzioni allo storico, provate sul motore vero.
//
//  ⚠️ Perché servono questi controlli: qui si riscrivono ore già registrate.
//  Un errore non fa cadere niente e non stampa nulla, semplicemente il totale
//  del giorno diventa un altro numero, e chi lo guarda non ha modo di sapere
//  che è sbagliato. È il tipo di difetto che si scopre mesi dopo, quando non
//  si ricorda più quante ore erano davvero.
//
//  Il file dei dati veri non viene toccato: il tracker scrive in Application
//  Support, e il test lavora sulle voci che crea lui e che rimuove alla fine.
//

#import <Cocoa/Cocoa.h>
#import "XPTracker.h"
#import "XPTimeEntry.h"
#import "XPPaths.h"

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

static NSDate *at(NSInteger hour, NSInteger minute) {
    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSDateComponents *parts = [calendar components:(NSCalendarUnitYear | NSCalendarUnitMonth |
                                                    NSCalendarUnitDay)
                                          fromDate:[NSDate date]];
    parts.hour = hour;
    parts.minute = minute;
    return [calendar dateFromComponents:parts];
}

static XPTrackableProject *fakeProject(void) {
    XPTrackableProject *project = [[XPTrackableProject alloc] init];
    project.key = @"test:trackertest";
    project.name = @"trackertest";
    return project;
}

int main(void) { @autoreleasepool {
    printf("\n\033[1mLo storico, corretto a mano\033[0m\n");

    XPTracker *tracker = [XPTracker shared];
    NSMutableArray<XPTimeEntry *> *creati = [NSMutableArray array];

    // ---------------------------------------------------------------------
    section(@"Aggiungere una sessione mai cronometrata");

    XPTimeEntry *entry = [tracker addEntryForProject:fakeProject()
                                                task:@"scritta a mano"
                                               start:at(9, 0)
                                                 end:at(11, 30)];
    check(entry != nil, @"la sessione si crea");
    if (entry) [creati addObject:entry];
    check(entry != nil && fabs(entry.duration - 2.5 * 3600) < 1,
          @"dura quanto dicono i suoi estremi");
    check(entry != nil && [entry.task isEqualToString:@"scritta a mano"],
          @"si porta dietro la descrizione");

    XPTimeEntry *rovesciata = [tracker addEntryForProject:fakeProject()
                                                    task:@"al contrario"
                                                   start:at(15, 0)
                                                     end:at(14, 0)];
    check(rovesciata == nil, @"una fine prima dell'inizio viene rifiutata");

    XPTimeEntry *istantanea = [tracker addEntryForProject:fakeProject()
                                                    task:@"zero"
                                                   start:at(12, 0)
                                                     end:at(12, 0)];
    check(istantanea == nil, @"una sessione di durata zero viene rifiutata");

    XPTimeEntry *orfana = [tracker addEntryForProject:nil
                                                 task:@"senza progetto"
                                                start:at(9, 0)
                                                  end:at(10, 0)];
    check(orfana == nil, @"senza progetto non si crea");

    // ---------------------------------------------------------------------
    section(@"Correggere una sessione registrata");

    BOOL ok = [tracker updateEntry:entry start:at(9, 0) end:at(10, 0) task:@"corretta"];
    check(ok, @"la correzione va a buon fine");
    check(fabs(entry.duration - 3600) < 1, @"la durata segue i nuovi estremi");
    check([entry.task isEqualToString:@"corretta"], @"la descrizione cambia");

    BOOL rifiutata = [tracker updateEntry:entry start:at(10, 0) end:at(9, 0) task:nil];
    check(!rifiutata, @"invertire gli estremi viene rifiutato");
    check(fabs(entry.duration - 3600) < 1,
          @"e la sessione resta com'era: un rifiuto non lascia dati a metà");

    [tracker updateEntry:entry start:at(9, 0) end:at(10, 0) task:nil];
    check([entry.task isEqualToString:@"corretta"],
          @"task nil lascia la descrizione dov'era");

    [tracker updateEntry:entry start:at(9, 0) end:at(10, 0) task:@""];
    check(entry.task.length == 0, @"una stringa vuota invece la cancella");

    // ---------------------------------------------------------------------
    section(@"I totali seguono le correzioni");

    NSDate *oggi = [[NSCalendar currentCalendar] startOfDayForDate:[NSDate date]];
    NSTimeInterval prima = [tracker totalForProjectKey:@"test:trackertest" onDay:oggi];
    check(fabs(prima - 3600) < 2, @"il totale del progetto è un'ora");

    [tracker updateEntry:entry start:at(9, 0) end:at(12, 0) task:nil];
    NSTimeInterval dopo = [tracker totalForProjectKey:@"test:trackertest" onDay:oggi];
    check(fabs(dopo - 3 * 3600) < 2, @"allungando la sessione il totale sale");

    // ---------------------------------------------------------------------
    section(@"Eliminare");

    NSUInteger quante = [tracker entriesForDay:oggi].count;
    [tracker deleteEntry:entry];
    [creati removeObject:entry];
    check([tracker entriesForDay:oggi].count == quante - 1, @"la sessione sparisce");
    check([tracker totalForProjectKey:@"test:trackertest" onDay:oggi] < 1,
          @"e il totale del progetto torna a zero");

    // ---------------------------------------------------------------------
    section(@"L'elenco dei progetti");

    NSArray<XPTrackableProject *> *projects = [tracker allProjects];
    check(projects.count > 0, @"qualche progetto c'è");

    NSMutableSet<NSString *> *nomi = [NSMutableSet set];
    BOOL duplicati = NO;
    for (XPTrackableProject *p in projects) {
        NSString *lower = [p.name lowercaseString] ?: @"";
        if ([nomi containsObject:lower]) duplicati = YES;
        [nomi addObject:lower];
    }
    check(!duplicati, @"nessun progetto compare due volte");

    BOOL daCartella = NO;
    for (XPTrackableProject *p in projects) {
        if ([p.key hasPrefix:@"folder:"]) { daCartella = YES; break; }
    }
    // Su una macchina appena installata www/projects è vuota e non ci sono
    // cartelle: il controllo vale solo se ce ne sono.
    if ([XPPaths projectFolders].count > 0) {
        check(daCartella, @"le cartelle di www/projects sono fra i progetti");
    } else {
        check(YES, @"nessuna cartella in www/projects, niente da verificare");
    }

    // Pulizia: quello che il test ha creato non resta nello storico vero.
    for (XPTimeEntry *rimasto in creati) [tracker deleteEntry:rimasto];
    for (XPTimeEntry *rimasto in [tracker entriesForDay:oggi]) {
        if ([rimasto.projectKey isEqualToString:@"test:trackertest"]) {
            [tracker deleteEntry:rimasto];
        }
    }
    check([tracker totalForProjectKey:@"test:trackertest" onDay:oggi] < 1,
          @"il test non lascia sessioni dietro di sé");

    printf("\n\033[1m%d passati, %d falliti\033[0m\n\n", sPassed, sFailed);
    return sFailed == 0 ? 0 : 1;
}}
