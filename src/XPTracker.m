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
@property (nonatomic, strong, readwrite) XPTimeEntry *currentEntry;
@property (nonatomic, strong) NSMutableArray<XPTimeEntry *> *entries;
@property (nonatomic, strong) NSMutableArray<XPTrackableProject *> *customProjects;
@property (nonatomic, strong) NSTimer *tickTimer;
@property (nonatomic, strong) NSTimer *idleTimer;
/// true quando la pausa è stata decisa dall'app e non dall'utente: solo queste
/// vengono annullate da sole quando l'utente torna a lavorare.
@property (nonatomic, assign) BOOL pausedAutomatically;
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
        _customProjects = [NSMutableArray array];
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

        if (self.currentEntry) [self startTicking];
    }
    return self;
}

- (void)dealloc {
    [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self];
    [self.tickTimer invalidate];
    [self.idleTimer invalidate];
}

#pragma mark - Sessione

- (void)startProject:(XPTrackableProject *)project task:(NSString *)task {
    if (!project) return;
    // Una sola sessione per volta: iniziarne un'altra chiude la precedente,
    // che è ciò che ci si aspetta passando da un progetto all'altro.
    if (self.currentEntry) [self stop];

    XPTimeEntry *entry = [[XPTimeEntry alloc] init];
    entry.projectKey  = project.key;
    entry.projectName = project.name;
    entry.task        = task;
    entry.startDate   = [NSDate date];

    self.currentEntry = entry;
    self.pausedAutomatically = NO;
    [self startTicking];
    [self save];
    [self notifyChange];
}

- (void)pause {
    if (!self.currentEntry || self.currentEntry.isPaused) return;
    self.currentEntry.pauseStartedAt = [NSDate date];
    self.pausedAutomatically = NO;
    [self save];
    [self notifyChange];
}

- (void)resume {
    if (!self.currentEntry || !self.currentEntry.isPaused) return;
    self.currentEntry.pausedSeconds +=
        [[NSDate date] timeIntervalSinceDate:self.currentEntry.pauseStartedAt];
    self.currentEntry.pauseStartedAt = nil;
    self.pausedAutomatically = NO;
    [self save];
    [self notifyChange];
}

- (void)stop {
    if (!self.currentEntry) return;

    // Una pausa aperta va chiusa prima, o resterebbe a scorrere per sempre.
    if (self.currentEntry.isPaused) {
        self.currentEntry.pausedSeconds +=
            [[NSDate date] timeIntervalSinceDate:self.currentEntry.pauseStartedAt];
        self.currentEntry.pauseStartedAt = nil;
    }
    self.currentEntry.endDate = [NSDate date];

    // Sessioni di pochi secondi sono quasi sempre un clic per sbaglio.
    if (self.currentEntry.duration >= 5) {
        [self.entries addObject:self.currentEntry];
    }

    self.currentEntry = nil;
    self.pausedAutomatically = NO;
    [self.tickTimer invalidate];
    self.tickTimer = nil;
    [self save];
    [self notifyChange];
}

- (void)startTicking {
    [self.tickTimer invalidate];
    // Un colpo al secondo: serve solo a far avanzare il cronometro a video.
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
    if (!self.currentEntry) return;

    NSTimeInterval idle = SecondsSinceLastInput();

    if (!self.currentEntry.isPaused && idle >= XPIdleThreshold) {
        // La pausa si fa decorrere da quando l'inattività è iniziata, non da
        // adesso: i minuti già passati senza toccare nulla non sono lavoro.
        self.currentEntry.pauseStartedAt = [NSDate dateWithTimeIntervalSinceNow:-idle];
        self.pausedAutomatically = YES;
        [self save];
        [self notifyChange];
        return;
    }

    // Ripresa automatica solo se era stata l'app a mettere in pausa: una pausa
    // decisa dall'utente resta finché non la toglie lui.
    if (self.currentEntry.isPaused && self.pausedAutomatically && idle < XPIdleCheckInterval) {
        [self resume];
    }
}

- (void)systemWillSleep:(NSNotification *)note {
    if (self.currentEntry && !self.currentEntry.isPaused) {
        self.currentEntry.pauseStartedAt = [NSDate date];
        self.pausedAutomatically = YES;
        [self save];
    }
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

    // La sessione aperta va contata: il totale di oggi deve salire mentre si
    // lavora, non solo dopo lo stop.
    if (self.currentEntry) {
        NSCalendar *calendar = [NSCalendar currentCalendar];
        if ([[calendar startOfDayForDate:self.currentEntry.startDate]
             isEqualToDate:[calendar startOfDayForDate:day]]) {
            total += self.currentEntry.duration;
        }
    }
    return total;
}

- (NSTimeInterval)totalForProjectKey:(NSString *)key onDay:(NSDate *)day {
    NSTimeInterval total = 0;
    for (XPTimeEntry *entry in [self entriesForDay:day]) {
        if ([entry.projectKey isEqualToString:key]) total += entry.duration;
    }
    if (self.currentEntry && [self.currentEntry.projectKey isEqualToString:key]) {
        NSCalendar *calendar = [NSCalendar currentCalendar];
        if ([[calendar startOfDayForDate:self.currentEntry.startDate]
             isEqualToDate:[calendar startOfDayForDate:day]]) {
            total += self.currentEntry.duration;
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
    if (self.currentEntry && [self.currentEntry.projectKey isEqualToString:key]) {
        total += self.currentEntry.duration;
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
    NSString *directory = [paths.firstObject
                           stringByAppendingPathComponent:@"it.chirurgiadigitale.xampp"];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory
                             withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:NULL];
    return [directory stringByAppendingPathComponent:@"timesheet.json"];
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

    // Una sessione lasciata aperta da un avvio precedente viene ripresa: se
    // l'app è stata chiusa senza premere stop, il lavoro non va perso.
    XPTimeEntry *current = [XPTimeEntry entryFromDictionary:root[@"current"]];
    if (current && current.isRunning) self.currentEntry = current;
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
    if (self.currentEntry) root[@"current"] = [self.currentEntry dictionaryRepresentation];

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
