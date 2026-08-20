//
//  XPUpdateCheck.m
//

#import "XPUpdateCheck.h"

NSString *const XPUpdateCheckDidFinishNotification = @"XPUpdateCheckDidFinish";

/// Il file che dice qual è l'ultima versione. Statico, servito dal sito.
///
/// ⚠️ Non è l'API di GitHub. Quella impone un limite di richieste per
/// indirizzo IP e risponde 403 quando lo si supera, e un utente dietro la
/// stessa uscita di rete di altri si vedrebbe negare il controllo senza
/// capire perché. Un file statico non ha limiti e non ha nulla da autenticare.
static NSString *const XPVersionURL = @"https://vxost.com/version.json";

/// Una volta al giorno. Più spesso non serve: le versioni non escono a ore.
static const NSTimeInterval XPCheckInterval = 24 * 60 * 60;

/// All'avvio si aspetta, perché in quel momento l'utente sta guardando la
/// finestra che si apre, non ha chiesto niente alla rete.
static const NSTimeInterval XPStartupDelay = 20;

static NSString *const XPAutomaticKey = @"UpdateCheckEnabled";
static NSString *const XPLastCheckKey = @"UpdateCheckLast";

@interface XPUpdateCheck ()
@property (nonatomic, copy) NSString *availableVersion;
@property (nonatomic, copy) NSString *downloadURL;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, strong) NSURLSession *session;
/// Il controllo in corso è stato chiesto da una persona?
/// Chi chiede aspetta una risposta anche quando la risposta è "niente di
/// nuovo"; il controllo di sfondo tace, o sarebbe un avviso al giorno per
/// dire che non è successo nulla.
@property (nonatomic, assign) BOOL manual;

/// L'ultimo controllo non è arrivato a leggere un numero di versione.
/// Serve perché "non ho potuto controllare" e "sei aggiornato" hanno lo
/// stesso availableVersion, cioè nil, ma non vanno detti nello stesso modo.
@property (nonatomic, assign) BOOL failed;
@end

@implementation XPUpdateCheck

+ (instancetype)shared {
    static XPUpdateCheck *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[XPUpdateCheck alloc] init]; });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;

    // ⚠️ Sessione effimera: niente cache su disco, niente cookie, niente
    // credenziali conservate. Una richiesta che non lascia tracce sul Mac è
    // anche una richiesta che non ne porta al server.
    NSURLSessionConfiguration *config =
        [NSURLSessionConfiguration ephemeralSessionConfiguration];
    config.HTTPShouldSetCookies = NO;
    config.HTTPCookieAcceptPolicy = NSHTTPCookieAcceptPolicyNever;
    config.timeoutIntervalForRequest = 15;
    config.URLCache = nil;
    // Senza la versione installata: il confronto lo fa l'app, il server non ha
    // bisogno di sapere da dove si parte.
    config.HTTPAdditionalHeaders = @{@"User-Agent": @"VXOST update check"};
    _session = [NSURLSession sessionWithConfiguration:config];

    return self;
}

#pragma mark - Preferenza

- (BOOL)automatic {
    // Acceso finché non lo si spegne: la chiave assente vale sì, e
    // boolForKey: su una chiave assente risponde no. Quindi si guarda
    // l'oggetto, non il booleano.
    id stored = [[NSUserDefaults standardUserDefaults] objectForKey:XPAutomaticKey];
    return stored == nil ? YES : [stored boolValue];
}

- (void)setAutomatic:(BOOL)automatic {
    [[NSUserDefaults standardUserDefaults] setBool:automatic forKey:XPAutomaticKey];
    if (automatic) {
        [self scheduleTimer];
    } else {
        [self.timer invalidate];
        self.timer = nil;
        // Quello che si sapeva si dimentica: lasciando il messaggio "c'è la
        // 9.27" dopo aver spento il controllo, l'interruttore sembrerebbe non
        // aver fatto niente.
        self.availableVersion = nil;
        self.downloadURL = nil;
        [self postResult];
    }
}

- (NSDate *)lastCheck {
    return [[NSUserDefaults standardUserDefaults] objectForKey:XPLastCheckKey];
}

#pragma mark - Avvio

- (void)start {
    if (!self.automatic) return;

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(XPStartupDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || !self.automatic) return;

        // Se si è già controllato oggi non si ricontrolla: aprire e chiudere
        // l'app dieci volte in una mattina non sono dieci richieste.
        NSDate *last = self.lastCheck;
        if (!last || [[NSDate date] timeIntervalSinceDate:last] >= XPCheckInterval) {
            [self checkAnnouncing:NO];
        }
        [self scheduleTimer];
    });
}

- (void)scheduleTimer {
    [self.timer invalidate];
    __weak typeof(self) weakSelf = self;
    self.timer = [NSTimer scheduledTimerWithTimeInterval:XPCheckInterval
                                                 repeats:YES
                                                   block:^(NSTimer *timer) {
        (void)timer;
        __strong typeof(weakSelf) self = weakSelf;
        if (self.automatic) [self checkAnnouncing:NO];
    }];
    // L'app resta aperta per giorni: il timer deve scattare anche mentre un
    // menu è aperto, che altrimenti bloccherebbe il run loop di default.
    [[NSRunLoop mainRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];
}

#pragma mark - Controllo

- (void)checkNow {
    [self checkAnnouncing:YES];
}

- (void)checkAnnouncing:(BOOL)manual {
    self.manual = manual;
    NSURL *url = [NSURL URLWithString:XPVersionURL];
    __weak typeof(self) weakSelf = self;

    NSURLSessionDataTask *task = [self.session dataTaskWithURL:url
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSString *version = nil;
        NSString *download = nil;
        // ⚠️ "Non ho potuto controllare" e "sei aggiornato" non sono la stessa
        // cosa, e dirle con la stessa frase e' una bugia: chi legge "questa e'
        // l'ultima versione" con la rete staccata resta indietro convinto di
        // essere avanti. Oggi vxost.com/version.json risponde 404 perche' il
        // sito non e' pubblicato, ed e' esattamente questo il caso.
        __block BOOL failed = YES;

        if (!error && data) {
            NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
            if (![http isKindOfClass:[NSHTTPURLResponse class]] || http.statusCode == 200) {
                NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data
                                                                     options:0
                                                                       error:NULL];
                // ⚠️ Quello che arriva dalla rete si controlla tipo per tipo.
                // Un JSON con "version" numerico farebbe cadere l'app sul
                // primo messaggio inviato a un NSNumber.
                if ([json isKindOfClass:[NSDictionary class]]) {
                    id v = json[@"version"];
                    id u = json[@"url"];
                    if ([v isKindOfClass:[NSString class]]) version = v;
                    if ([u isKindOfClass:[NSString class]]) download = u;
                }
                // Riuscito vuol dire "ho letto un numero di versione", non
                // "il server ha risposto": una pagina di errore con codice
                // 200, o un JSON senza il campo, non sono una risposta.
                failed = (version == nil);
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;

            // La data si segna comunque, anche se il controllo è fallito: una
            // rete assente non deve diventare una richiesta a ogni minuto.
            [[NSUserDefaults standardUserDefaults] setObject:[NSDate date]
                                                      forKey:XPLastCheckKey];

            NSString *current = [[NSBundle mainBundle]
                                 objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
            if (version && current &&
                [XPUpdateCheck compareVersion:version with:current] == NSOrderedDescending) {
                self.availableVersion = version;
                self.downloadURL = download ?: @"https://vxost.com/download/";
            } else {
                self.availableVersion = nil;
                self.downloadURL = nil;
            }
            self.failed = failed;
            [self postResult];
        });
    }];
    [task resume];
}

- (void)postResult {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[@"available"] = @(self.availableVersion != nil);
    info[@"manual"] = @(self.manual);
    info[@"failed"] = @(self.failed);
    if (self.availableVersion) info[@"version"] = self.availableVersion;
    if (self.downloadURL) info[@"url"] = self.downloadURL;

    [[NSNotificationCenter defaultCenter]
        postNotificationName:XPUpdateCheckDidFinishNotification
                      object:self
                    userInfo:info];
}

#pragma mark - Confronto

+ (NSComparisonResult)compareVersion:(NSString *)a with:(NSString *)b {
    // Si confrontano i numeri uno per uno, non le stringhe: per l'ordine
    // alfabetico "9.9.0" viene dopo "9.26.0", e non è così.
    NSArray<NSString *> *left  = [(a ?: @"") componentsSeparatedByString:@"."];
    NSArray<NSString *> *right = [(b ?: @"") componentsSeparatedByString:@"."];
    NSUInteger count = MAX(left.count, right.count);

    for (NSUInteger i = 0; i < count; i++) {
        // Una versione più corta vale zero nelle posizioni che le mancano:
        // 9.26 e 9.26.0 sono la stessa versione.
        NSInteger l = i < left.count  ? left[i].integerValue  : 0;
        NSInteger r = i < right.count ? right[i].integerValue : 0;
        if (l < r) return NSOrderedAscending;
        if (l > r) return NSOrderedDescending;
    }
    return NSOrderedSame;
}

@end
