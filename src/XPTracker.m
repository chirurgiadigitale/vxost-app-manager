//
//  XPTracker.m
//

#import "XPTracker.h"
#import "XPVirtualHost.h"

#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>

NSString *const XPTrackerDidChangeNotification = @"XPTrackerDidChangeNotification";

/// Dopo quanti secondi senza tastiera né mouse la sessione va in pausa da sola.
static const NSTimeInterval XPIdleThreshold = 10 * 60;

/// Ogni quanto si controlla l'inattività.
static const NSTimeInterval XPIdleCheckInterval = 30;


@implementation XPTrackableProject
@end


@interface XPTracker ()
@property (nonatomic, strong) NSMutableArray<XPTimeEntry *> *openEntries;
@property (nonatomic, strong) NSMutableArray<XPTimeEntry *> *entries;
@property (nonatomic, strong) NSMutableArray<XPTrackableProject *> *customProjects;
@property (nonatomic, strong) NSTimer *tickTimer;
@property (nonatomic, strong) NSTimer *idleTimer;
/// Identificatori delle sessioni messe in pausa dall'app e non dall'utente:
/// solo queste vengono riprese da sole quando si torna a lavorare.
@property (nonatomic, strong) NSMutableSet<NSString *> *automaticallyPaused;
@end


@implementation XPTracker

+ (instancetype)shared {
    static XPTracker *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[XPTracker alloc] init]; });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _entries = [NSMutableArray array];
        _openEntries = [NSMutableArray array];
        _customProjects = [NSMutableArray array];
        _automaticallyPaused = [NSMutableSet set];
        [self load];

        // Il Mac che va in stop non deve gonfiare la sessione: si mette in
        // pausa prima di dormire e si riprende al risveglio.
        NSNotificationCenter *workspace = [[NSWorkspace sharedWorkspace] notificationCenter];
        [workspace addObserver:self selector:@selector(systemWillSleep:)
                          name:NSWorkspaceWillSleepNotification object:nil];
        [workspace addObserver:self selector:@selector(systemDidWake:)
                          name:NSWorkspaceDidWakeNotification object:nil];

        _idleTimer = [NSTimer scheduledTimerWithTimeInterval:XPIdleCheckInterval
                                                     repeats:YES
                                                       block:^(NSTimer *t) { [self checkIdle]; }];
        [[NSRunLoop mainRunLoop] addTimer:_idleTimer forMode:NSRunLoopCommonModes];

        if (self.openEntries.count > 0) [self startTicking];
    }
    return self;
}

- (void)dealloc {
    [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self];
    [self.tickTimer invalidate];
    [self.idleTimer invalidate];
}

#pragma mark - Sessioni

- (NSArray<XPTimeEntry *> *)currentEntries {
    return [self.openEntries copy];
}

- (XPTimeEntry *)currentEntryForProjectKey:(NSString *)key {
    for (XPTimeEntry *entry in self.openEntries) {
        if ([entry.projectKey isEqualToString:key]) return entry;
    }
    return nil;
}

- (void)startProject:(XPTrackableProject *)project task:(NSString *)task {
    if (!project) return;
    // Lo stesso progetto due volte in parallelo conterebbe il tempo doppio.
    if ([self currentEntryForProjectKey:project.key]) return;

    XPTimeEntry *entry = [[XPTimeEntry alloc] init];
    entry.projectKey  = project.key;
    entry.projectName = project.name;
    entry.task        = task;
    entry.startDate   = [NSDate date];

    [self.openEntries addObject:entry];
    [self startTicking];
    [self save];
    [self notifyChange];
}

- (void)pauseEntry:(XPTimeEntry *)entry {
    if (!entry || entry.isPaused || ![self.openEntries containsObject:entry]) return;
    entry.pauseStartedAt = [NSDate date];
    [self.automaticallyPaused removeObject:entry.identifier];
    [self save];
    [self notifyChange];
}

- (void)resumeEntry:(XPTimeEntry *)entry {
    if (!entry || !entry.isPaused || ![self.openEntries containsObject:entry]) return;
    entry.pausedSeconds += [[NSDate date] timeIntervalSinceDate:entry.pauseStartedAt];
    entry.pauseStartedAt = nil;
    [self.automaticallyPaused removeObject:entry.identifier];
    [self save];
    [self notifyChange];
}

- (void)stopEntry:(XPTimeEntry *)entry {
    if (!entry || ![self.openEntries containsObject:entry]) return;

    // Una pausa aperta va chiusa prima, o resterebbe a scorrere per sempre.
    if (entry.isPaused) {
        entry.pausedSeconds += [[NSDate date] timeIntervalSinceDate:entry.pauseStartedAt];
        entry.pauseStartedAt = nil;
    }
    entry.endDate = [NSDate date];

    // Sessioni di pochi secondi sono quasi sempre un clic per sbaglio.
    if (entry.duration >= 5) [self.entries addObject:entry];

    [self.openEntries removeObject:entry];
    [self.automaticallyPaused removeObject:entry.identifier];

    if (self.openEntries.count == 0) {
        [self.tickTimer invalidate];
        self.tickTimer = nil;
    }
    [self save];
    [self notifyChange];
}

- (void)stopAll {
    for (XPTimeEntry *entry in [self.openEntries copy]) [self stopEntry:entry];
}

- (NSTimeInterval)runningTotal {
    NSTimeInterval total = 0;
    for (XPTimeEntry *entry in self.openEntries) total += entry.duration;
    return total;
}

- (void)startTicking {
    if (self.tickTimer) return;
    // Un colpo al secondo: serve solo a far avanzare i cronometri a video.
    self.tickTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                     repeats:YES
                                                       block:^(NSTimer *t) {
        [self notifyChange];
    }];
    [[NSRunLoop mainRunLoop] addTimer:self.tickTimer forMode:NSRunLoopCommonModes];
}

#pragma mark - Pause automatiche

/// Secondi trascorsi dall'ultimo evento di tastiera o mouse.
static NSTimeInterval SecondsSinceLastInput(void) {
    return CGEventSourceSecondsSinceLastEventType(kCGEventSourceStateCombinedSessionState,
                                                  kCGAnyInputEventType);
}

- (void)checkIdle {
    if (self.openEntries.count == 0) return;

    NSTimeInterval idle = SecondsSinceLastInput();

    // L'inattività riguarda la persona, non il singolo progetto: mette in
    // pausa tutte le sessioni aperte insieme.
    for (XPTimeEntry *entry in self.openEntries) {
        if (!entry.isPaused && idle >= XPIdleThreshold) {
            // La pausa decorre da quando l'inattività è iniziata, non da
            // adesso: i minuti già passati senza toccare nulla non sono lavoro.
            entry.pauseStartedAt = [NSDate dateWithTimeIntervalSinceNow:-idle];
            [self.automaticallyPaused addObject:entry.identifier];
            continue;
        }

        // Ripresa automatica solo per le pause decise dall'app: una pausa
        // scelta dall'utente resta finché non la toglie lui.
        if (entry.isPaused &&
            [self.automaticallyPaused containsObject:entry.identifier] &&
            idle < XPIdleCheckInterval) {
            entry.pausedSeconds += [[NSDate date] timeIntervalSinceDate:entry.pauseStartedAt];
            entry.pauseStartedAt = nil;
            [self.automaticallyPaused removeObject:entry.identifier];
        }
    }

    [self save];
    [self notifyChange];
}

- (void)systemWillSleep:(NSNotification *)note {
    for (XPTimeEntry *entry in self.openEntries) {
        if (entry.isPaused) continue;
        entry.pauseStartedAt = [NSDate date];
        [self.automaticallyPaused addObject:entry.identifier];
    }
    [self save];
}

- (void)systemDidWake:(NSNotification *)note {
    // Al risveglio non si riprende da soli: chi torna al Mac dopo ore deve
    // decidere lui se quel tempo era lavoro.
    [self notifyChange];
}

#pragma mark - Progetti

- (NSArray<XPTrackableProject *> *)allProjects {
    NSMutableArray<XPTrackableProject *> *projects = [NSMutableArray array];

    for (XPVirtualHost *host in [XPVirtualHost allHosts]) {
        XPTrackableProject *project = [[XPTrackableProject alloc] init];
        project.key  = [NSString stringWithFormat:@"vhost:%ld", (long)host.port];
        project.name = host.name;
        project.isCustom = NO;
        [projects addObject:project];
    }

    [projects addObjectsFromArray:self.customProjects];
    return projects;
}

- (XPTrackableProject *)addCustomProjectNamed:(NSString *)name {
    NSString *trimmed = [name stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) return nil;

    NSString *key = [NSString stringWithFormat:@"custom:%@", trimmed];
    for (XPTrackableProject *existing in [self allProjects]) {
        if ([existing.key isEqualToString:key]) return nil;
    }

    XPTrackableProject *project = [[XPTrackableProject alloc] init];
    project.key = key;
    project.name = trimmed;
    project.isCustom = YES;
    [self.customProjects addObject:project];
    [self save];
    [self notifyChange];
    return project;
}

- (void)removeCustomProjectWithKey:(NSString *)key {
    NSUInteger index = NSNotFound;
    for (NSUInteger i = 0; i < self.customProjects.count; i++) {
        if ([self.customProjects[i].key isEqualToString:key]) { index = i; break; }
    }
    if (index == NSNotFound) return;

    [self.customProjects removeObjectAtIndex:index];
    [self save];
    [self notifyChange];
}

#pragma mark - Storico

- (NSArray<XPTimeEntry *> *)entriesForDay:(NSDate *)day {
    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSDate *start = [calendar startOfDayForDate:day];

    NSMutableArray *result = [NSMutableArray array];
    for (XPTimeEntry *entry in self.entries) {
        if ([[calendar startOfDayForDate:entry.startDate] isEqualToDate:start]) {
            [result addObject:entry];
        }
    }
    [result sortUsingComparator:^NSComparisonResult(XPTimeEntry *a, XPTimeEntry *b) {
        return [b.startDate compare:a.startDate];
    }];
    return result;
}

- (NSArray<NSDate *> *)daysWithEntries {
    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSMutableSet<NSDate *> *days = [NSMutableSet set];
    for (XPTimeEntry *entry in self.entries) {
        [days addObject:[calendar startOfDayForDate:entry.startDate]];
    }
    return [[days allObjects] sortedArrayUsingComparator:^NSComparisonResult(NSDate *a, NSDate *b) {
        return [b compare:a];
    }];
}

- (NSTimeInterval)totalForDay:(NSDate *)day {
    NSTimeInterval total = 0;
    for (XPTimeEntry *entry in [self entriesForDay:day]) total += entry.duration;

    // Le sessioni aperte vanno contate: il totale di oggi deve salire mentre
    // si lavora, non solo dopo lo stop.
    NSCalendar *calendar = [NSCalendar currentCalendar];
    for (XPTimeEntry *entry in self.openEntries) {
        if ([[calendar startOfDayForDate:entry.startDate]
             isEqualToDate:[calendar startOfDayForDate:day]]) {
            total += entry.duration;
        }
    }
    return total;
}

- (NSTimeInterval)totalForProjectKey:(NSString *)key onDay:(NSDate *)day {
    NSTimeInterval total = 0;
    for (XPTimeEntry *entry in [self entriesForDay:day]) {
        if ([entry.projectKey isEqualToString:key]) total += entry.duration;
    }
    NSCalendar *calendar = [NSCalendar currentCalendar];
    for (XPTimeEntry *entry in self.openEntries) {
        if (![entry.projectKey isEqualToString:key]) continue;
        if ([[calendar startOfDayForDate:entry.startDate]
             isEqualToDate:[calendar startOfDayForDate:day]]) {
            total += entry.duration;
        }
    }
    return total;
}

- (NSTimeInterval)totalForProjectKey:(NSString *)key lastDays:(NSInteger)days {
    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSDate *limit = [calendar dateByAddingUnit:NSCalendarUnitDay
                                          value:-(days - 1)
                                         toDate:[calendar startOfDayForDate:[NSDate date]]
                                        options:0];
    NSTimeInterval total = 0;
    for (XPTimeEntry *entry in self.entries) {
        if ([entry.projectKey isEqualToString:key] &&
            [entry.startDate compare:limit] != NSOrderedAscending) {
            total += entry.duration;
        }
    }
    for (XPTimeEntry *entry in self.openEntries) {
        if ([entry.projectKey isEqualToString:key]) total += entry.duration;
    }
    return total;
}

- (void)deleteEntry:(XPTimeEntry *)entry {
    [self.entries removeObject:entry];
    [self save];
    [self notifyChange];
}

#pragma mark - Persistenza

- (NSString *)storagePath {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                                                         NSUserDomainMask, YES);
    NSString *support = paths.firstObject;
    NSString *directory = [support stringByAppendingPathComponent:@"it.equipedigitale.vxost"];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:directory withIntermediateDirectories:YES
                   attributes:nil error:NULL];

    NSString *path = [directory stringByAppendingPathComponent:@"timesheet.json"];

    // ⚠️ Le ore registrate prima della rinomina stanno sotto il vecchio
    // identificatore del bundle, e senza questo passaggio l'app parte con lo
    // storico vuoto: i dati non sono persi, semplicemente sono in una cartella
    // che nessuno guarda piu'. Succede a chiunque aggiorni da una versione
    // precedente, non solo qui.
    //
    // Si copia, non si sposta: se qualcosa va storto l'originale e' ancora al
    // suo posto, e sono ore di lavoro vero.
    if (![fm fileExistsAtPath:path]) {
        NSString *legacy = [[support stringByAppendingPathComponent:@"it.chirurgiadigitale.xampp"]
                            stringByAppendingPathComponent:@"timesheet.json"];
        if ([fm fileExistsAtPath:legacy]) {
            NSError *error = nil;
            if ([fm copyItemAtPath:legacy toPath:path error:&error]) {
                NSLog(@"VXOST: storico del time tracking recuperato da %@", legacy);
            } else {
                NSLog(@"VXOST: impossibile recuperare lo storico da %@: %@",
                      legacy, error.localizedDescription);
            }
        }
    }
    return path;
}

- (void)load {
    NSData *data = [NSData dataWithContentsOfFile:[self storagePath]];
    if (!data) return;

    NSDictionary *root = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (![root isKindOfClass:[NSDictionary class]]) return;

    for (NSDictionary *raw in root[@"entries"]) {
        XPTimeEntry *entry = [XPTimeEntry entryFromDictionary:raw];
        if (entry) [self.entries addObject:entry];
    }

    for (NSString *name in root[@"customProjects"]) {
        if (![name isKindOfClass:[NSString class]]) continue;
        XPTrackableProject *project = [[XPTrackableProject alloc] init];
        project.key = [NSString stringWithFormat:@"custom:%@", name];
        project.name = name;
        project.isCustom = YES;
        [self.customProjects addObject:project];
    }

    // Le sessioni lasciate aperte da un avvio precedente vengono riprese: se
    // l'app è stata chiusa senza premere stop, il lavoro non va perso.
    // "current" al singolare è il formato della prima versione, letto ancora
    // per non perdere i dati di chi aggiorna.
    for (NSDictionary *raw in root[@"open"]) {
        XPTimeEntry *entry = [XPTimeEntry entryFromDictionary:raw];
        if (entry && entry.isRunning) [self.openEntries addObject:entry];
    }
    XPTimeEntry *legacy = [XPTimeEntry entryFromDictionary:root[@"current"]];
    if (legacy && legacy.isRunning) [self.openEntries addObject:legacy];
}

- (void)save {
    NSMutableArray *entries = [NSMutableArray array];
    for (XPTimeEntry *entry in self.entries) {
        [entries addObject:[entry dictionaryRepresentation]];
    }

    NSMutableArray *customNames = [NSMutableArray array];
    for (XPTrackableProject *project in self.customProjects) {
        [customNames addObject:project.name];
    }

    NSMutableDictionary *root = [NSMutableDictionary dictionary];
    root[@"version"] = @1;
    root[@"entries"] = entries;
    root[@"customProjects"] = customNames;
    NSMutableArray *open = [NSMutableArray array];
    for (XPTimeEntry *entry in self.openEntries) {
        [open addObject:[entry dictionaryRepresentation]];
    }
    root[@"open"] = open;

    NSData *data = [NSJSONSerialization dataWithJSONObject:root
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:NULL];
    // Scrittura atomica: un'interruzione a metà lascerebbe il file dei tempi
    // troncato, e sono ore di lavoro.
    [data writeToFile:[self storagePath] atomically:YES];
}

- (void)notifyChange {
    [[NSNotificationCenter defaultCenter] postNotificationName:XPTrackerDidChangeNotification
                                                        object:self];
}

@end
