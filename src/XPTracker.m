//
//  XPTracker.m
//

#import "XPTracker.h"
#import "XPVirtualHost.h"
#import "XPPaths.h"

#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>

NSString *const XPTrackerDidChangeNotification = @"XPTrackerDidChangeNotification";

/// Dopo quanti secondi senza tastiera né mouse la sessione va in pausa da sola.
static const NSTimeInterval XPIdleThreshold = 10 * 60;

/// Ogni quanto si controlla l'inattività.
static const NSTimeInterval XPIdleCheckInterval = 30;


@implementation XPTrackableProject
@end


@interface XPTracker () {
    /// Il file esiste ma non si e' riusciti a leggerlo. Finche' vale YES non
    /// si salva niente: riscrivere quel file vorrebbe dire completare una
    /// perdita di dati invece di limitarla.
    BOOL _storageUnusable;
}
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
        // ⚠️ Una pausa che attraversa un sonno non si riprende da sola, e per
        // questo NON entra in automaticallyPaused.
        //
        // Ci entrava, e la promessa di systemDidWake — "chi torna al Mac dopo
        // ore decide lui se quel tempo era lavoro" — durava fino al primo
        // movimento del mouse: checkIdle riprende ogni sessione che trova in
        // quell'insieme appena l'inattività scende sotto la soglia. Il
        // risveglio la fa scendere sempre. Il conteggio restava giusto, ma il
        // cronometro ripartiva senza che nessuno lo avesse chiesto, ed e' la
        // differenza fra un tempo misurato e un tempo supposto.
        //
        // Vale anche per chi era gia' in pausa automatica: da qui in poi
        // quella pausa ha attraversato un sonno, e diventa una scelta.
        [self.automaticallyPaused removeObject:entry.identifier];
        if (entry.isPaused) continue;
        entry.pauseStartedAt = [NSDate date];
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

    // ⚠️ I virtual host non sono i progetti.
    //
    // Prima l'elenco veniva solo da httpd-vhosts.conf, e su questa macchina
    // vuol dire sette voci contro sessantatre cartelle in www/projects: su un
    // progetto senza porta dedicata le ore non si potevano registrare affatto.
    // Un vhost e' un progetto pubblicato, non tutto il lavoro che si fa.
    //
    // Le fonti sono tre e in quest'ordine: prima i virtual host, che hanno un
    // nome scelto da chi li ha scritti, poi le cartelle, poi le voci create a
    // mano. Chi arriva dopo con lo stesso nome non entra, cosi' il progetto
    // che ha sia il vhost sia la cartella compare una volta sola.
    NSMutableSet<NSString *> *visti = [NSMutableSet set];

    for (XPVirtualHost *host in [XPVirtualHost allHosts]) {
        XPTrackableProject *project = [[XPTrackableProject alloc] init];
        project.key  = [NSString stringWithFormat:@"vhost:%ld", (long)host.port];
        project.name = host.name;
        project.isCustom = NO;
        [projects addObject:project];
        if (host.name) [visti addObject:[host.name lowercaseString]];
    }

    for (NSString *folder in [XPPaths projectFolders]) {
        if ([visti containsObject:[folder lowercaseString]]) continue;
        XPTrackableProject *project = [[XPTrackableProject alloc] init];
        // La chiave porta il nome della cartella, non la posizione
        // nell'elenco: rinominare una cartella accanto non deve spostare le
        // ore gia' registrate su questa.
        project.key  = [NSString stringWithFormat:@"folder:%@", folder];
        project.name = folder;
        project.isCustom = NO;
        [projects addObject:project];
        [visti addObject:[folder lowercaseString]];
    }

    for (XPTrackableProject *custom in self.customProjects) {
        if (custom.name && [visti containsObject:[custom.name lowercaseString]]) continue;
        [projects addObject:custom];
        if (custom.name) [visti addObject:[custom.name lowercaseString]];
    }

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

- (BOOL)updateEntry:(XPTimeEntry *)entry
              start:(NSDate *)start
                end:(NSDate *)end
               task:(NSString *)task {
    if (!entry || !start || !end) return NO;
    // Una fine prima dell'inizio dà durata negativa, e il totale del giorno
    // scenderebbe aggiungendo lavoro. Si rifiuta qui: l'interfaccia mostra il
    // motivo, ma il motore non deve fidarsi di chi lo chiama.
    if ([end compare:start] != NSOrderedDescending) return NO;

    entry.startDate = start;
    entry.endDate   = end;
    if (task) entry.task = task;

    // La sessione può essere finita in un altro giorno: l'elenco è ordinato
    // per data e va rimesso in ordine, o lo storico mostrerebbe le voci
    // mescolate.
    [self.entries sortUsingComparator:^NSComparisonResult(XPTimeEntry *a, XPTimeEntry *b) {
        return [b.startDate compare:a.startDate];
    }];

    [self save];
    [self notifyChange];
    return YES;
}

- (XPTimeEntry *)addEntryForProject:(XPTrackableProject *)project
                               task:(NSString *)task
                              start:(NSDate *)start
                                end:(NSDate *)end {
    if (!project || !start || !end) return nil;
    if ([end compare:start] != NSOrderedDescending) return nil;

    XPTimeEntry *entry = [[XPTimeEntry alloc] init];
    entry.projectKey  = project.key;
    entry.projectName = project.name;
    entry.task        = task;
    entry.startDate   = start;
    entry.endDate     = end;

    [self.entries addObject:entry];
    [self.entries sortUsingComparator:^NSComparisonResult(XPTimeEntry *a, XPTimeEntry *b) {
        return [b.startDate compare:a.startDate];
    }];

    [self save];
    [self notifyChange];
    return entry;
}

#pragma mark - Persistenza

- (NSString *)storagePath {
    // ⚠️ La via d'uscita per i test, e solo per loro.
    //
    // trackertest usa XPTracker.shared, quindi senza questo scriveva nello
    // storico vero: creava sessioni, le cancellava alla fine, e se falliva a
    // meta' le lasciava li'. Peggio, girando mentre l'app e' aperta, l'ultimo
    // salvataggio dell'una sovrascriveva quello dell'altro, e le ore perse
    // non tornano.
    NSString *override = NSProcessInfo.processInfo.environment[@"VXOST_TRACKER_STORE"];
    if (override.length > 0) {
        [[NSFileManager defaultManager]
            createDirectoryAtPath:[override stringByDeletingLastPathComponent]
      withIntermediateDirectories:YES attributes:nil error:NULL];
        return override;
    }

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
    NSString *path = [self storagePath];
    NSFileManager *fm = [NSFileManager defaultManager];

    // Nessun file: primo avvio. È l'unico caso in cui "storico vuoto" è la
    // lettura giusta, e va distinto da tutti gli altri.
    if (![fm fileExistsAtPath:path]) return;

    NSError *error = nil;
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:&error];
    if (!data) {
        // ⛔ Il file c'è ma non si legge. Continuare vorrebbe dire partire con
        // lo storico vuoto e riscriverlo vuoto al primo salvataggio, cioè
        // cancellare mesi di ore per un permesso sbagliato o un disco che fa
        // i capricci. Meglio non avere niente da mostrare che perdere tutto.
        NSLog(@"VXOST: lo storico esiste ma non si legge (%@). "
              @"Non verrà sovrascritto.", error.localizedDescription);
        _storageUnusable = YES;
        return;
    }

    NSDictionary *root = [NSJSONSerialization JSONObjectWithData:data
                                                         options:0 error:&error];
    if (![root isKindOfClass:[NSDictionary class]]) {
        // JSON rotto: si mette da parte con la data, invece di lasciarlo
        // sovrascrivere. Quello che c'è dentro è spesso ancora leggibile a
        // mano, e comunque non tocca a noi decidere di buttarlo.
        NSString *stamp = [@(time(NULL)) stringValue];
        NSString *quarantine = [path stringByAppendingFormat:@".corrupt-%@", stamp];
        if ([fm moveItemAtPath:path toPath:quarantine error:&error]) {
            NSLog(@"VXOST: lo storico non è JSON valido. Messo da parte in %@, "
                  @"si riparte da zero senza perdere il file.", quarantine);
        } else {
            NSLog(@"VXOST: lo storico non è JSON valido e non si riesce a "
                  @"metterlo da parte (%@). Non verrà sovrascritto.",
                  error.localizedDescription);
            _storageUnusable = YES;
        }
        return;
    }

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

    // Se il file esisteva e non si è riusciti a leggerlo, non lo si tocca:
    // sovrascriverlo con quello che c'è in memoria vorrebbe dire completare
    // la perdita invece di limitarla.
    if (_storageUnusable) {
        NSLog(@"VXOST: salvataggio saltato, lo storico su disco non è leggibile.");
        return;
    }

    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:root
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:&error];
    if (!data) {
        NSLog(@"VXOST: le ore non si riescono a convertire in JSON (%@). "
              @"Niente è stato scritto.", error.localizedDescription);
        return;
    }

    // Scrittura atomica: un'interruzione a metà lascerebbe il file dei tempi
    // troncato, e sono ore di lavoro.
    //
    // ⚠️ L'esito si guarda. Disco pieno, cartella senza permessi, volume
    // smontato: senza questo controllo l'app continua a mostrare le ore in
    // finestra come se fossero al sicuro, e non lo sono.
    if (![data writeToFile:[self storagePath] options:NSDataWritingAtomic
                     error:&error]) {
        NSLog(@"VXOST: le ore non sono state salvate (%@)",
              error.localizedDescription);
    }
}

- (void)notifyChange {
    [[NSNotificationCenter defaultCenter] postNotificationName:XPTrackerDidChangeNotification
                                                        object:self];
}

@end
