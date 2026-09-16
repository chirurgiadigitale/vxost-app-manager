//
//  XPActions.m
//

#import "XPActions.h"
#import "XPPaths.h"
#import "XPServiceMonitor.h"
#import "XPTaskRunner.h"
#import "XPDatabase.h"
#import "XPPhpVersion.h"
#import "XPUpdateCheck.h"
#import "XPExposure.h"

NSString *const XPActionMessageNotification = @"XPActionMessageNotification";

@implementation XPActions

+ (instancetype)shared {
    static XPActions *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[XPActions alloc] init]; });
    return shared;
}

#pragma mark - Esecuzione

/// Esegue un'azione dello script vxost marcando i servizi come "in transizione".
///
/// Il messaggio di avanzamento arriva già formato e tradotto: comporlo qui da
/// pezzi ("Avvio" + "di" + nome) darebbe frasi sgrammaticate in metà delle
/// lingue supportate.
- (void)performAction:(NSString *)action
           onServices:(NSArray<XPService *> *)services
      progressMessage:(NSString *)progressMessage {

    for (XPService *service in services) service.state = XPServiceStateBusy;
    [[NSNotificationCenter defaultCenter] postNotificationName:XPServicesDidChangeNotification
                                                        object:self];
    [self postMessage:progressMessage isError:NO];

    [XPTaskRunner runPrivilegedVxostAction:action completion:^(XPTaskResult *result) {
        // Lo stato torna a essere dedotto dai processi reali.
        for (XPService *service in services) service.state = XPServiceStateStopped;

        if (result.cancelled) {
            [self postMessage:NSLocalizedString(@"msg.cancelled", nil) isError:NO];
        } else if (!result.succeeded) {
            [self postMessage:[self firstMeaningfulLine:result.output] isError:YES];
        } else {
            [self postMessage:NSLocalizedString(@"msg.done", nil) isError:NO];
        }

        // I demoni impiegano un istante a comparire o sparire dalla tabella dei
        // processi: si rilegge subito e poi ancora dopo un secondo.
        [[XPServiceMonitor shared] refreshNow];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [[XPServiceMonitor shared] refreshNow];
        });
    }];
}

- (NSString *)firstMeaningfulLine:(NSString *)output {
    for (NSString *line in [output componentsSeparatedByString:@"\n"]) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:
                             [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length > 0) return trimmed;
    }
    return NSLocalizedString(@"msg.failed", nil);
}

#pragma mark - Servizi

- (void)toggleService:(XPService *)service {
    BOOL running = (service.state == XPServiceStateRunning);
    NSString *format = running ? NSLocalizedString(@"progress.stopping", nil)
                               : NSLocalizedString(@"progress.starting", nil);
    [self performAction:(running ? service.stopAction : service.startAction)
             onServices:@[service]
        progressMessage:[NSString stringWithFormat:format, service.name]];
}

- (void)reloadService:(XPService *)service {
    [self performAction:service.reloadAction
             onServices:@[service]
        progressMessage:[NSString stringWithFormat:
                         NSLocalizedString(@"progress.reloading", nil), service.name]];
}

- (void)startAll {
    [self performAction:@"start"
             onServices:[XPServiceMonitor shared].services
        progressMessage:NSLocalizedString(@"progress.startingAll", nil)];
}

- (void)stopAll {
    [self performAction:@"stop"
             onServices:[XPServiceMonitor shared].services
        progressMessage:NSLocalizedString(@"progress.stoppingAll", nil)];
}

- (void)restartAll {
    [self performAction:@"restart"
             onServices:[XPServiceMonitor shared].services
        progressMessage:NSLocalizedString(@"progress.restartingAll", nil)];
}

#pragma mark - Collegamenti

- (void)openDashboard {
    [self openURLString:[NSString stringWithFormat:@"http://%@/dashboard/", [XPPaths localHostname]]];
}

- (void)openPhpMyAdmin {
    [self openURLString:[NSString stringWithFormat:@"http://%@/phpmyadmin/", [XPPaths localHostname]]];
}

- (void)openURLString:(NSString *)urlString {
    // Con Apache fermo il browser mostrerebbe soltanto un errore di
    // connessione: meglio dirlo prima di aprirlo.
    XPService *apache = [[XPServiceMonitor shared] serviceForKey:@"apache"];
    if (apache.state != XPServiceStateRunning) {
        [self postMessage:NSLocalizedString(@"msg.apacheStopped", nil) isError:YES];
        return;
    }
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:urlString]];
}

- (void)openHtdocs {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:[XPPaths htdocs]]];
}

- (void)openVirtualHost:(XPVirtualHost *)host {
    if (!host) return;

    if (host.state == XPVHostStateDisabled) {
        [self postMessage:[NSString stringWithFormat:
            NSLocalizedString(@"vhost.err.commented", nil), (long)host.port] isError:YES];
        return;
    }
    if (host.state != XPVHostStateListening) {
        [self postMessage:[NSString stringWithFormat:
            NSLocalizedString(@"vhost.err.noResponse", nil), (long)host.port] isError:YES];
        return;
    }
    [[NSWorkspace sharedWorkspace] openURL:[host url]];
}

- (void)openVxostFolder {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:[XPPaths installRoot]]];
}

- (void)revealFile:(NSString *)path {
    if (!path) return;
    BOOL isDirectory = NO;
    [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDirectory];

    if (isDirectory) {
        [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:path]];
    } else {
        // Si mostra nel Finder invece di aprirlo: i file di configurazione
        // appartengono a root e un editor non potrebbe comunque salvarli.
        [[NSWorkspace sharedWorkspace] selectFile:path inFileViewerRootedAtPath:@""];
    }
}

#pragma mark - Strumenti

- (void)enableSSL {
    [self confirmThenRun:@"enablessl"
                 message:NSLocalizedString(@"alert.enableSSL", nil)
         progressMessage:NSLocalizedString(@"progress.enablingSSL", nil)];
}

- (void)disableSSL {
    [self confirmThenRun:@"disablessl"
                 message:NSLocalizedString(@"alert.disableSSL", nil)
         progressMessage:NSLocalizedString(@"progress.disablingSSL", nil)];
}

- (void)confirmThenRun:(NSString *)action
               message:(NSString *)message
       progressMessage:(NSString *)progressMessage {

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = NSLocalizedString(@"alert.confirm.title", nil);
    alert.informativeText = message;
    [alert addButtonWithTitle:NSLocalizedString(@"btn.proceed", nil)];
    [alert addButtonWithTitle:NSLocalizedString(@"btn.cancel", nil)];
    alert.alertStyle = NSAlertStyleWarning;

    [NSApp activateIgnoringOtherApps:YES];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;

    [self performAction:action
             onServices:[XPServiceMonitor shared].services
        progressMessage:progressMessage];
}

- (void)runSecurityCheck { [self runInTerminal:@"security"]; }
- (void)runBackup        { [self runInTerminal:@"backup"]; }

/// Apre il Terminale sul comando indicato: `security` e `backup` fanno domande
/// e in esecuzione silenziosa resterebbero appesi in attesa di risposta.
- (void)runInTerminal:(NSString *)action {
    NSString *command = [NSString stringWithFormat:@"sudo '%@' %@", [XPPaths controlScript], action];
    NSString *source = [NSString stringWithFormat:
        @"tell application \"Terminal\"\n"
        @"  activate\n"
        @"  do script \"%@\"\n"
        @"end tell", command];

    NSAppleScript *script = [[NSAppleScript alloc] initWithSource:source];
    NSDictionary *error = nil;
    [script executeAndReturnError:&error];
    if (error) {
        [self postMessage:NSLocalizedString(@"msg.terminalFailed", nil) isError:YES];
    } else {
        [self postMessage:NSLocalizedString(@"msg.terminalOpened", nil) isError:NO];
    }
}

#pragma mark - Informazioni

- (void)showAbout {
    NSString *appVersion = [[NSBundle mainBundle]
                            objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"";
    NSString *stackVersion = [XPPaths vxostVersion];

    // Il pannello standard di macOS mostra quello che gli si passa, e i campi
    // liberi sono due: Version e Credits. Ci stanno release e autore, che nel
    // plist non hanno un posto che il pannello legga.
    NSMutableParagraphStyle *paragraph = [[NSMutableParagraphStyle alloc] init];
    paragraph.alignment = NSTextAlignmentCenter;
    paragraph.paragraphSpacing = 4;

    NSString *credits = [NSString stringWithFormat:
        @"%@\n\n%@\nwww.chirurgiadigitale.it\n\n%@",
        NSLocalizedString(@"about.release", nil),
        NSLocalizedString(@"about.author", nil),
        NSLocalizedString(@"about.licence", nil)];

    NSDictionary *attributes = @{
        NSFontAttributeName: [NSFont systemFontOfSize:11],
        NSForegroundColorAttributeName: [NSColor secondaryLabelColor],
        NSParagraphStyleAttributeName: paragraph,
    };

    NSString *versionLine = stackVersion.length > 0
        ? [NSString stringWithFormat:@"%@ · stack %@", appVersion, stackVersion]
        : appVersion;

    [NSApp activateIgnoringOtherApps:YES];
    [NSApp orderFrontStandardAboutPanelWithOptions:@{
        @"ApplicationName": @"VXOST",
        @"Version": versionLine,
        @"Credits": [[NSAttributedString alloc] initWithString:credits attributes:attributes],
    }];
}

// Il controllo vive qui e non nel controller del menu perché lo chiamano in
// due: il menu contestuale della barra di stato e il menu dell'applicazione.
// L'esito non torna al chiamante, arriva come XPActionMessageNotification,
// così lo vede anche l'interfaccia da cui non è partito.
- (void)checkForUpdates {
    [self postMessage:NSLocalizedString(@"update.checking", nil) isError:NO];

    // ⚠️ postMessage scrive nel popover e nella finestra: chiamato dal menu
    // dell'applicazione sono chiusi tutti e due, e l'esito non ha dove
    // comparire. L'avviso arriva comunque, anche a finestra aperta: chi ha
    // chiesto di controllare vuole una risposta che non gli sfugga, e una
    // riga in fondo a una finestra si perde. Deciso da Davide il 20/08.
    __block id token = [[NSNotificationCenter defaultCenter]
        addObserverForName:XPUpdateCheckDidFinishNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        [[NSNotificationCenter defaultCenter] removeObserver:token];

        NSAlert *alert = [[NSAlert alloc] init];
        if ([note.userInfo[@"available"] boolValue]) {
            alert.messageText = [NSString stringWithFormat:
                NSLocalizedString(@"update.available", nil), note.userInfo[@"version"]];
            [alert addButtonWithTitle:NSLocalizedString(@"update.download", nil)];
            [alert addButtonWithTitle:NSLocalizedString(@"btn.cancel", nil)];
        } else {
            alert.messageText = NSLocalizedString(
                [note.userInfo[@"failed"] boolValue] ? @"update.failed" : @"update.current", nil);
            [alert addButtonWithTitle:NSLocalizedString(@"btn.ok", nil)];
        }

        [NSApp activateIgnoringOtherApps:YES];
        if ([alert runModal] == NSAlertFirstButtonReturn && note.userInfo[@"url"]) {
            [self openURLString:note.userInfo[@"url"]];
        }
    }];

    [[XPUpdateCheck shared] checkNow];
}


#pragma mark - Nuovo progetto

/// Porte già dichiarate in httpd.conf, righe commentate comprese.
///
/// Le commentate contano: una porta spenta a mano appartiene comunque a un
/// progetto, e riassegnarla farebbe scoppiare il conflitto il giorno in cui
/// qualcuno toglie il commento. È il caso della 4003 su questa macchina.
static NSSet<NSNumber *> *XPDeclaredPorts(void) {
    NSMutableSet<NSNumber *> *ports = [NSMutableSet set];
    NSString *conf = [NSString stringWithContentsOfFile:[XPPaths root:@"etc/httpd.conf"]
                                               encoding:NSUTF8StringEncoding
                                                  error:NULL];
    if (conf.length == 0) return ports;

    NSRegularExpression *re =
        [NSRegularExpression regularExpressionWithPattern:
            @"^[ \\t]*#*[ \\t]*Listen[ \\t]+(?:[0-9.]+:)?([0-9]{1,5})"
                                                  options:NSRegularExpressionAnchorsMatchLines
                                                    error:NULL];
    [re enumerateMatchesInString:conf
                         options:0
                           range:NSMakeRange(0, conf.length)
                      usingBlock:^(NSTextCheckingResult *m, NSMatchingFlags flags, BOOL *stop) {
        [ports addObject:@([[conf substringWithRange:[m rangeAtIndex:1]] integerValue])];
    }];
    return ports;
}

/// Cartella del progetto sotto htdocs/projects.
static NSString *XPProjectFolder(NSString *name) {
    return [[XPPaths htdocs] stringByAppendingPathComponent:
            [@"projects" stringByAppendingPathComponent:name]];
}

+ (NSInteger)suggestedPort {
    NSSet<NSNumber *> *declared = XPDeclaredPorts();

    // Si parte dalla fascia che il progetto usa già per i vhost, non dalla 80.
    NSInteger candidate = 4000;
    for (NSNumber *port in declared) {
        if (port.integerValue >= candidate && port.integerValue < 65000) {
            candidate = port.integerValue + 1;
        }
    }
    while (candidate < 65535 &&
           ([declared containsObject:@(candidate)] ||
            [XPService portIsListening:(uint16_t)candidate timeout:0.1])) {
        candidate++;
    }
    return candidate;
}

+ (NSString *)validationErrorForProjectName:(NSString *)name {
    NSString *trimmed = [name stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];

    if (trimmed.length == 0) return NSLocalizedString(@"wizard.err.nameEmpty", nil);

    // Il nome finisce in un percorso, in un nome di file di log e dentro lo
    // script che gira come root: l'insieme dei caratteri ammessi è ristretto
    // apposta, così non c'è niente da citare e niente da sfuggire.
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:
                               @"^[a-z0-9][a-z0-9-]{1,39}$" options:0 error:NULL];
    if ([re numberOfMatchesInString:trimmed options:0
                              range:NSMakeRange(0, trimmed.length)] == 0) {
        return NSLocalizedString(@"wizard.err.nameFormat", nil);
    }

    if ([[NSFileManager defaultManager] fileExistsAtPath:XPProjectFolder(trimmed)]) {
        return NSLocalizedString(@"wizard.err.nameTaken", nil);
    }
    return nil;
}

+ (NSString *)validationErrorForPort:(NSInteger)port {
    if (port < 1024 || port > 65535) {
        return NSLocalizedString(@"wizard.err.portRange", nil);
    }
    if ([XPDeclaredPorts() containsObject:@(port)] ||
        [XPService portIsListening:(uint16_t)port timeout:0.2]) {
        return [NSString stringWithFormat:NSLocalizedString(@"wizard.err.portBusy", nil), (long)port];
    }
    return nil;
}

/// L'indirizzo del repository è accettato solo nelle due forme che GitHub,
/// GitLab e Bitbucket usano davvero. Non è pignoleria: serve a non passare a
/// git una stringa qualsiasi scritta a mano.
static BOOL XPRepositoryURLIsValid(NSString *url) {
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:
        @"^(https://[a-z0-9.-]+/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+(\\.git)?/?"
        @"|[a-z]+@[a-z0-9.-]+:[A-Za-z0-9._-]+/[A-Za-z0-9._-]+(\\.git)?)$"
                                                                       options:0 error:NULL];
    return [re numberOfMatchesInString:url options:0 range:NSMakeRange(0, url.length)] > 0;
}

- (void)createProjectNamed:(NSString *)name
                   summary:(NSString *)summary
                repository:(NSString *)repositoryURL
                      port:(NSInteger)port
                phpVersion:(XPPhpVersion *)phpVersion
                  database:(NSString *)database
                completion:(void (^)(BOOL ok))completion {

    NSCharacterSet *spaces = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSString *project = [name stringByTrimmingCharactersInSet:spaces];
    NSString *repository = [(repositoryURL ?: @"") stringByTrimmingCharactersInSet:spaces];

    // Ricontrollo, anche se la finestra ha già validato: chi scrive la riga di
    // comando che diventa root non si fida di quello che gli passa la UI.
    NSString *problem = [XPActions validationErrorForProjectName:project]
                     ?: [XPActions validationErrorForPort:port];
    if (!problem && repository.length > 0 && !XPRepositoryURLIsValid(repository)) {
        problem = NSLocalizedString(@"wizard.err.repoFormat", nil);
    }
    if (problem) {
        [self postMessage:problem isError:YES];
        if (completion) completion(NO);
        return;
    }

    NSString *folder = XPProjectFolder(project);
    [self postMessage:(repository.length > 0
                       ? NSLocalizedString(@"wizard.progress.cloning", nil)
                       : NSLocalizedString(@"wizard.progress.creating", nil)) isError:NO];

    // Il clone può metterci parecchio: fuori dal main thread, sempre.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *failure = [self prepareFolder:folder
                                     repository:repository
                                        project:project
                                           port:port];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (failure) {
                [self postMessage:failure isError:YES];
                if (completion) completion(NO);
                return;
            }
            [self installVirtualHostForProject:project
                                       summary:summary
                                        folder:folder
                                          port:port
                                    phpVersion:phpVersion
                                      database:database
                                    completion:completion];
        });
    });
}

/// Clona il repository, oppure crea una cartella con una pagina minima.
/// Restituisce il motivo del fallimento, nil se è andata.
- (NSString *)prepareFolder:(NSString *)folder
                 repository:(NSString *)repository
                    project:(NSString *)project
                       port:(NSInteger)port {

    NSFileManager *fm = [NSFileManager defaultManager];

    if (repository.length > 0) {
        // Argomenti in array, non riga di shell: così l'indirizzo non passa mai
        // da un interprete di comandi. Il `--` separa le opzioni dagli argomenti.
        XPTaskResult *result = [XPTaskRunner run:@"/usr/bin/git"
                                       arguments:@[@"clone", @"--", repository, folder]];
        if (!result.succeeded) {
            // Un clone interrotto lascia una cartella a metà: va tolta, altrimenti
            // il secondo tentativo fallisce dicendo che il nome è già preso.
            [fm removeItemAtPath:folder error:NULL];
            return [self firstMeaningfulLine:result.output];
        }
        return nil;
    }

    NSError *error = nil;
    if (![fm createDirectoryAtPath:folder
       withIntermediateDirectories:YES attributes:nil error:&error]) {
        return error.localizedDescription;
    }

    // Una pagina minima: senza, la porta risponderebbe con l'elenco di una
    // cartella vuota e sembrerebbe che qualcosa non abbia funzionato.
    NSString *index = [NSString stringWithFormat:
        @"<!doctype html>\n<html lang=\"en\">\n<meta charset=\"utf-8\">\n"
        @"<title>%@</title>\n<h1>%@</h1>\n<p>Served by VXOST on port %ld.</p>\n",
        project, project, (long)port];
    [index writeToFile:[folder stringByAppendingPathComponent:@"index.html"]
            atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    return nil;
}

/// Scrive il virtual host e apre la porta, come amministratore.
- (void)installVirtualHostForProject:(NSString *)project
                             summary:(NSString *)summary
                              folder:(NSString *)folder
                                port:(NSInteger)port
                          phpVersion:(XPPhpVersion *)phpVersion
                            database:(NSString *)database
                          completion:(void (^)(BOOL ok))completion {

    NSFileManager *fm = [NSFileManager defaultManager];

    // Laravel, Symfony e i progetti con front controller si servono da una
    // sottocartella. Puntare alla radice mostrerebbe i sorgenti e il .env.
    NSString *docroot = folder;
    for (NSString *candidate in @[@"public", @"public_html", @"web", @"dist"]) {
        NSString *sub = [folder stringByAppendingPathComponent:candidate];
        BOOL isDirectory = NO;
        if ([fm fileExistsAtPath:sub isDirectory:&isDirectory] && isDirectory) {
            docroot = sub;
            break;
        }
    }

    // Lo script va su file invece che dentro la stringa di AppleScript: un
    // programma di venti righe con virgolette e heredoc, passato a
    // "do shell script", diventa illeggibile e si rompe al primo apostrofo.
    // La cartella temporanea su macOS è privata dell'utente (/var/folders/…),
    // e il file nasce comunque con permessi 0700.
    NSString *scriptPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"vxost-new-project-%@.sh", [NSUUID UUID].UUIDString]];

    NSError *error = nil;
    if (![[self privilegedScriptForProject:project summary:summary
                                                docroot:docroot port:port
                                             phpVersion:phpVersion]
            writeToFile:scriptPath atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
        [self postMessage:error.localizedDescription isError:YES];
        if (completion) completion(NO);
        return;
    }
    [fm setAttributes:@{NSFilePosixPermissions: @(0700)} ofItemAtPath:scriptPath error:NULL];

    [self postMessage:NSLocalizedString(@"wizard.progress.vhost", nil) isError:NO];

    [XPTaskRunner runPrivilegedShell:[NSString stringWithFormat:@"/bin/sh '%@'", scriptPath]
                          completion:^(XPTaskResult *result) {
        [fm removeItemAtPath:scriptPath error:NULL];

        BOOL ok = NO;
        NSString *message;
        if (result.cancelled) {
            message = NSLocalizedString(@"msg.cancelled", nil);
        } else if ([result.output containsString:@"VXOST_BACKUP_FAILED"]) {
            message = NSLocalizedString(@"wizard.failed.backup", nil);
        } else if ([result.output containsString:@"VXOST_CONFIGTEST_FAILED"]) {
            message = NSLocalizedString(@"wizard.failed.configtest", nil);
        } else if ([result.output containsString:@"VXOST_RESTART_FAILED"]) {
            message = NSLocalizedString(@"wizard.failed.restart", nil);
        // ⚠️ Prima di VXOST_OK, perche' containsString: lo trova anche dentro
        // VXOST_OK_UNVERIFIED: invertendo i due rami, un riavvio non
        // verificato passerebbe per verificato senza che niente lo dica.
        //
        // Il messaggio qui non e' tradotto, ed e' voluto: dice cosa non si e'
        // potuto verificare, e una frase tradotta che dichiari il successo
        // sarebbe una bugia in quindici lingue invece che in una.
        } else if ([result.output containsString:@"VXOST_OK_UNVERIFIED"]) {
            ok = YES;
            message = [self firstMeaningfulLine:result.output];
        } else if ([result.output containsString:@"VXOST_OK"]) {
            ok = YES;
            message = [NSString stringWithFormat:
                       NSLocalizedString(@"wizard.done", nil), project, (long)port];
        } else {
            message = [self firstMeaningfulLine:result.output];
        }

        [self postMessage:message isError:!ok];
        [[XPServiceMonitor shared] refreshNow];

        // Il database si crea per ultimo, a virtual host installato.
        //
        // ⚠️ L'ordine conta. Creandolo per primo, un configtest fallito
        // lascerebbe un database senza progetto: invisibile, e nessuno va a
        // cercarlo in phpMyAdmin. Al contrario, un progetto senza database si
        // vede subito e si rimedia con una riga.
        if (ok && database.length > 0) {
            [self postMessage:NSLocalizedString(@"wizard.progress.database", nil) isError:NO];
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                // Nessun utente dedicato: in locale ci si collega come root, e
                // una credenziale in piu' sarebbe una credenziale in piu' da
                // comunicare e da ricordare.
                NSString *dbProblem = [XPDatabase createDatabase:database
                                                            user:nil
                                                        password:nil];
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (dbProblem) {
                        // Il progetto c'e' e funziona: il database mancante e'
                        // un avviso, non un fallimento della creazione.
                        [self postMessage:[NSString stringWithFormat:
                                           NSLocalizedString(@"wizard.failed.database", nil),
                                           dbProblem] isError:YES];
                    } else {
                        [self postMessage:[NSString stringWithFormat:
                                           NSLocalizedString(@"wizard.done.database", nil),
                                           database] isError:NO];
                    }
                    if (completion) completion(YES);
                });
            });
            return;
        }

        if (completion) completion(ok);
    }];
}

/// Lo script che gira come root.
///
/// ⚠️ Esce sempre con 0 e comunica l'esito con un marcatore stampato:
/// `do shell script` di AppleScript trasforma un'uscita diversa da zero in un
/// errore proprio, e il codice vero non arriverebbe mai fin qui.
/// Il pezzo di script che riavvia Apache e **guarda se e' ripartito**.
///
/// ⚠️ Perche' non basta chiamare restartapache. Il controllo di sintassi dice
/// che la configurazione e' scritta bene, non che Apache riesca a usarla: una
/// porta gia' occupata supera "Syntax OK" e poi impedisce l'avvio. Prima di
/// questa verifica lo script stampava VXOST_OK in quel caso, quindi l'app
/// annunciava un progetto pronto mentre il server era giu' — e con lui tutti
/// gli altri progetti, non solo quello appena creato.
///
/// Apache scrive il proprio pid solo quando e' partito davvero, quindi la
/// prova e' quella: il file esiste e il processo che nomina e' vivo. Quando si
/// conosce anche la porta del progetto si controlla che qualcuno la stia
/// ascoltando, perche' un master rimasto in piedi con la configurazione
/// precedente supererebbe la prova del pid.
///
/// @param port La porta da verificare, o 0 per fermarsi al pid.
/// @param restore I comandi che rimettono i file com'erano, gia' indentati.
static NSString *XPApacheRestartBlock(NSInteger port, NSString *restore) {
    NSMutableString *block = [NSMutableString string];

    [block appendString:@"OUT=$(mktemp /tmp/vxost-apache.XXXXXX)\n"];
    // ⚠️ La prova che la configurazione nuova e' stata caricata non e' un pid
    // vivo (rilievo K). Un restart e' un SIGHUP: il padre resta lo stesso, e
    // "vivo" era vero anche a restart fallito, con il vecchio processo che
    // continuava a servire la configurazione vecchia. Apache scrive AH00163,
    // "resuming normal operations", quando ha riletto la configurazione e
    // riaperto le porte.
    //
    // ⚠️ Dove scrive lo dice Apache, non noi: ErrorLog si sposta, e un
    // percorso indovinato fa dichiarare fallito un riavvio riuscito. Se non
    // e' un file ordinario (syslog, o un programma dietro una pipe) la riga
    // non si puo' leggere: in quel caso valgono il pid e la porta, e non si
    // pretende di aver letto un log che non esiste.
    // ⚠️ Gli stessi -D dell'avvio (rilievo R8). Senza, i blocchi IfDefine
    // vengono letti diversamente da come li legge l'Apache vero, e
    // "Main ErrorLog" puo' uscire diverso da quello in uso.
    [block appendString:@"DEFS=\"-D PHP\"\n"];
    [block appendString:@"[ -f \"$R/etc/vxost/startssl\" ] && DEFS=\"$DEFS -D SSL\"\n"];
    [block appendString:@"LOG=$(\"$R/bin/httpd\" -t -d \"$R\" -f \"$HTTPD\" $DEFS -D DUMP_RUN_CFG 2>/dev/null \\\n"];
    [block appendString:@"      | sed -n 's/^Main ErrorLog: \"\\(.*\\)\"$/\\1/p' | head -1)\n"];
    // ⚠️ Un percorso che non si e' ottenuto NON si indovina. Prima il caso
    // vuoto ripiegava su $R/logs/error_log: se il log vero era altrove, il
    // riavvio riuscito veniva dichiarato fallito e si tornava indietro per
    // niente. Non sapere dove scrive si dice, e vale come "non verificabile".
    [block appendString:@"case \"$LOG\" in\n"];
    [block appendString:@"    \"\")      LOG='' ;;\n"];
    [block appendString:@"    syslog*) LOG='' ;;\n"];
    [block appendString:@"    \"|\"*)    LOG='' ;;\n"];
    [block appendString:@"    /*)      ;;\n"];
    [block appendString:@"    *)       LOG=\"$R/$LOG\" ;;\n"];
    [block appendString:@"esac\n"];
    [block appendString:@"\n"];
    // ⚠️ Che cosa prova che il messaggio appartiene a QUESTO tentativo.
    //
    // Nove giri di revisione su questa domanda, e ogni risposta aveva un
    // controesempio: il segno in byte, l'inode, il testo dell'ultima riga, il
    // conteggio. L'ultimo e' il piu' istruttivo: un log RISCRITTO con piu' righe
    // di prima (rotazione, ripristino, un altro Apache sullo stesso file) faceva
    // salire il conteggio senza che nessun riavvio fosse avvenuto.
    //
    // La domanda giusta e' un'altra: il file e' CRESCIUTO per aggiunta? Si misura
    // prima la dimensione e l'impronta dei suoi byte; dopo, se i primi N byte sono
    // ancora quelli, tutto quello che segue e' stato scritto dopo la misura, e il
    // messaggio si cerca SOLO li'. La data scarta le righe vecchie ricopiate in
    // coda; una riga dello stesso secondo della partenza non si distingue da
    // una copia, e l'esito e' "non verificabile".
    //
    // Se i primi N byte non sono piu' quelli, il log e' stato sostituito: resta
    // solo la data, strettamente successiva alla partenza, con il limite
    // dichiarato che un avvio nello stesso secondo di una rotazione non si prova.

    // Un file di lavoro, per non passare mai da una pipe: dopo una pipe "$?" e'
    // l'esito dell'ultimo comando, ed e' cosi' che un errore di lettura e' tornato
    // piu' volte a valere come prova.
    [block appendString:@"T=$(mktemp /tmp/vxost-log.XXXXXX)\n"];
    // ⚠️ I primi N byte del log, in $T. Con N = 0 non si chiama head: quello di
    // macOS rifiuta "-c 0" ed esce 1, e un log vuoto o non ancora creato
    // finiva sempre in "non verificabile", cioe' la prima partenza di
    // un'installazione nuova non si poteva mai provare.
    [block appendString:@"vxost_primi() {\n"];
    [block appendString:@"    if [ \"$1\" -eq 0 ]; then : > \"$T\"; else head -c \"$1\" \"$LOG\" > \"$T\" 2>/dev/null; fi\n"];
    [block appendString:@"}\n"];
    [block appendString:@"vxost_misura() {\n"];
    [block appendString:@"    [ -n \"$LOG\" ] && [ -n \"$T\" ] || return 1\n"];
    // Un log che ancora non esiste e' un log vuoto: la prima partenza di
    // un'installazione nuova deve potersi verificare.
    [block appendString:@"    if [ ! -e \"$LOG\" ]; then\n"];
    [block appendString:@"        _h=$(shasum -a 256 < /dev/null 2>/dev/null) || return 1\n"];
    [block appendString:@"        echo \"0 $_h\"; return 0\n"];
    [block appendString:@"    fi\n"];
    [block appendString:@"    [ -f \"$LOG\" ] || return 1\n"];
    [block appendString:@"    _s=$(stat -f %z \"$LOG\" 2>/dev/null) || return 1\n"];
    [block appendString:@"    case \"$_s\" in ''|*[!0-9]*) return 1 ;; esac\n"];
    // Si copiano ESATTAMENTE i primi _s byte e si controlla di averli: se il
    // file cresce fra stat e lettura, l'impronta resta quella dei byte misurati.
    [block appendString:@"    vxost_primi \"$_s\" || return 1\n"];
    [block appendString:@"    _s2=$(stat -f %z \"$T\" 2>/dev/null) || return 1\n"];
    [block appendString:@"    [ \"$_s2\" = \"$_s\" ] || return 1\n"];
    [block appendString:@"    _h=$(shasum -a 256 < \"$T\" 2>/dev/null) || return 1\n"];
    [block appendString:@"    echo \"$_s $_h\"\n"];
    [block appendString:@"}\n"];
    [block appendString:@"prima_m=$(vxost_misura) || prima_m=''\n"];
    [block appendString:@"prima_s=''; prima_h=''\n"];
    [block appendString:@"if [ -n \"$prima_m\" ]; then prima_s=${prima_m%% *}; prima_h=${prima_m#* }; fi\n"];
    // ⚠️ L'ora di partenza si prende DOPO la misura del log, non prima. Il
    // dodicesimo giro ha fatto arrivare una riga del nostro pid durante la
    // misura, nel secondo successivo a "prima" e oltre i byte misurati: il
    // controllo la trovava fra i byte aggiunti, con la data giusta, e diceva
    // VXOST_OK su un comando fallito. Presa qui, qualunque riga scritta prima
    // di questo punto ha una data non successiva, e non basta piu'.
    [block appendString:@"prima=$(date +%s)\n"];
    [block appendString:@"\n"];
    // L'ultima riga di ripartenza scritta da noi, o da un formato che il pid non
    // lo scrive. Una riga con il pid di un altro processo non conta. Nessuna
    // pipe: l'esito della funzione e' quello di awk.
    [block appendString:@"vxost_nostra_in() {\n"];
    [block appendString:@"    awk -v p=\"[pid $2]\" '/resuming normal operations/ && (index($0, p) > 0 || index($0, \"[pid \") == 0) { u = $0 } END { print u }' \"$1\" 2>/dev/null\n"];
    [block appendString:@"}\n"];
    [block appendString:@"vxost_epoca() {\n"];
    [block appendString:@"    _q=$(printf '%s\\n' \"$1\" | sed -n 's/^\\[\\([^]]*\\)\\].*/\\1/p' | sed 's/\\.[0-9]*//')\n"];
    // Qui una pipe fallita da' una stringa vuota, e la stringa vuota non diventa
    // mai una data: l'errore finisce in "non verificabile", non in "riuscito".
    [block appendString:@"    [ -n \"$_q\" ] || return 1\n"];
    [block appendString:@"    _ep=$(date -j -f '%a %b %d %T %Y' \"$_q\" '+%s' 2>/dev/null) || return 1\n"];
    [block appendString:@"    case \"$_ep\" in ''|*[!0-9]*) return 1 ;; esac\n"];
    [block appendString:@"    echo \"$_ep\"\n"];
    [block appendString:@"}\n"];
    [block appendString:@"\n"];
    // Tre esiti: 0 verificato, 2 vivo ma non verificabile, 1 no.
    [block appendString:@"vxost_ripartito() {\n"];
    [block appendString:@"    _da=\"$1\"; _da_s=\"$2\"; _da_h=\"$3\"\n"];
    [block appendString:@"    _pid=$(cat \"$R/logs/httpd.pid\" 2>/dev/null || echo '')\n"];
    [block appendString:@"    [ -n \"$_pid\" ] && kill -0 \"$_pid\" 2>/dev/null || return 1\n"];
    // Vivo non basta: dev'essere il NOSTRO httpd.
    [block appendString:@"    _cmd=$(ps -p \"$_pid\" -o comm= 2>/dev/null)\n"];
    [block appendString:@"    [ \"${_cmd##*/}\" = 'httpd' ] || return 1\n"];
    [block appendString:@"    case \"$_cmd\" in \"$R\"/*) ;; *) return 1 ;; esac\n"];
    [block appendString:@"    [ -n \"$LOG\" ] && [ -f \"$LOG\" ] || return 2\n"];
    // Senza la misura iniziale non c'e' niente con cui confrontare.
    [block appendString:@"    [ -n \"$_da_s\" ] && [ -n \"$_da_h\" ] || return 2\n"];
    [block appendString:@"    _adesso=$(date '+%s' 2>/dev/null) || return 2\n"];
    [block appendString:@"    _s=$(stat -f %z \"$LOG\" 2>/dev/null) || return 2\n"];
    [block appendString:@"    case \"$_s\" in ''|*[!0-9]*) return 2 ;; esac\n"];
    [block appendString:@"    _aggiunta=0\n"];
    [block appendString:@"    if [ \"$_s\" -ge \"$_da_s\" ]; then\n"];
    [block appendString:@"        vxost_primi \"$_da_s\" || return 2\n"];
    [block appendString:@"        _h=$(shasum -a 256 < \"$T\" 2>/dev/null) || return 2\n"];
    [block appendString:@"        [ \"$_h\" = \"$_da_h\" ] && _aggiunta=1\n"];
    [block appendString:@"    fi\n"];
    [block appendString:@"    if [ \"$_aggiunta\" = 1 ]; then\n"];
    [block appendString:@"        tail -c +\"$((_da_s + 1))\" \"$LOG\" > \"$T\" 2>/dev/null || return 2\n"];
    [block appendString:@"        _riga=$(vxost_nostra_in \"$T\" \"$_pid\") || return 2\n"];
    [block appendString:@"        [ -n \"$_riga\" ] || return 1\n"];
    [block appendString:@"        _ep=$(vxost_epoca \"$_riga\") || return 2\n"];
    // ⚠️ Nei byte aggiunti una riga NELLO STESSO SECONDO della partenza non
    // prova niente: l'undicesimo giro ha ricopiato in coda una riga gia'
    // presente, datata quel secondo, e il codice diceva VXOST_OK senza nessun
    // riavvio. Nessun controllo sulla riga distingue un evento nuovo da una
    // copia, quindi non si attesta: "vivo ma non verificabile". Un avvio
    // rapido non viene dichiarato fallito, e nemmeno riuscito.
    [block appendString:@"        [ \"$_ep\" -le \"$_adesso\" ] || return 1\n"];
    [block appendString:@"        [ \"$_ep\" -ge \"$_da\" ] || return 1\n"];
    [block appendString:@"        [ \"$_ep\" -gt \"$_da\" ] || return 2\n"];
    [block appendString:@"        return 0\n"];
    [block appendString:@"    fi\n"];
    // Il log e' stato sostituito: resta la data, strettamente successiva.
    [block appendString:@"    _riga=$(vxost_nostra_in \"$LOG\" \"$_pid\") || return 2\n"];
    [block appendString:@"    [ -n \"$_riga\" ] || return 1\n"];
    [block appendString:@"    _ep=$(vxost_epoca \"$_riga\") || return 2\n"];
    [block appendString:@"    [ \"$_ep\" -gt \"$_da\" ] && [ \"$_ep\" -le \"$_adesso\" ] || return 1\n"];
    [block appendString:@"    return 0\n"];
    [block appendString:@"}\n"];
    [block appendString:@"\n"];
    [block appendString:@"if pgrep -x httpd >/dev/null 2>&1; then\n"];
    [block appendString:@"    \"$CTL\" restartapache > \"$OUT\" 2>&1; ctl=$?\n"];
    [block appendString:@"else\n"];
    [block appendString:@"    \"$CTL\" startapache > \"$OUT\" 2>&1; ctl=$?\n"];
    [block appendString:@"fi\n"];
    [block appendString:@"\n"];
    // 1 verificato, 2 vivo ma non verificabile, 0 no.
    [block appendString:@"avviato=0\n"];
    [block appendString:@"attesa=0\n"];
    [block appendString:@"while [ $attesa -lt 15 ]; do\n"];
    [block appendString:@"    vxost_ripartito \"$prima\" \"$prima_s\" \"$prima_h\"; esito=$?\n"];
    [block appendString:@"    if [ $esito -eq 0 ]; then avviato=1; break; fi\n"];
    // Senza un log leggibile l'attesa non puo' portare nessuna prova nuova:
    // si concede il tempo di partire e si smette, invece di fermare l'utente
    // quindici secondi a ogni progetto su una macchina che logga su syslog.
    // ⚠️ Lo stato si riscrive a ogni tentativo. Restando appeso al 2 del
    // primo giro, Apache poteva sparire nel frattempo e il comando diceva
    // lo stesso "e' in esecuzione".
    [block appendString:@"    if [ $esito -eq 2 ]; then\n"];
    [block appendString:@"        avviato=2\n"];
    [block appendString:@"        [ $attesa -ge 3 ] && break\n"];
    [block appendString:@"    else\n"];
    [block appendString:@"        avviato=0\n"];
    [block appendString:@"    fi\n"];
    [block appendString:@"    sleep 1\n"];
    [block appendString:@"    attesa=$((attesa + 1))\n"];
    [block appendString:@"done\n"];

    if (port > 0) {
        [block appendString:@"\n"];
        [block appendString:@"# Vivo non basta: deve ascoltare la porta del progetto nuovo.\n"];
        [block appendString:@"if [ $avviato -ne 0 ]; then\n"];
        // ⚠️ Non basta che la porta sia occupata: deve tenerla IL NOSTRO
        // httpd. Un altro programma in ascolto su quella porta faceva
        // promuovere "non verificabile" a "verificato", cioe' dichiarava
        // riuscito un riavvio guardando il processo di qualcun altro.
        [block appendString:@"    inascolto=0\n"];
        [block appendString:@"    attesa=0\n"];
        [block appendString:@"    while [ $attesa -lt 15 ]; do\n"];
        [block appendFormat:@"        for _lp in $(/usr/sbin/lsof -nP -iTCP:%ld -sTCP:LISTEN -t 2>/dev/null); do\n",
                            (long)port];
        [block appendString:@"            _lc=$(ps -p \"$_lp\" -o comm= 2>/dev/null)\n"];
        [block appendString:@"            [ \"${_lc##*/}\" = 'httpd' ] || continue\n"];
        [block appendString:@"            case \"$_lc\" in \"$R\"/*) inascolto=1 ;; esac\n"];
        [block appendString:@"        done\n"];
        [block appendString:@"        if [ $inascolto -eq 1 ]; then\n"];
        [block appendString:@"            break\n"];
        [block appendString:@"        fi\n"];
        [block appendString:@"        sleep 1\n"];
        [block appendString:@"        attesa=$((attesa + 1))\n"];
        [block appendString:@"    done\n"];
        // ⚠️ La porta nuova viene dalla configurazione nuova: se e' in
        // ascolto, quella configurazione e' stata caricata. E' una prova
        // vera, e vale anche quando il log non si puo' leggere.
        [block appendString:@"    if [ $inascolto -eq 1 ]; then avviato=1; else avviato=0; fi\n"];
        [block appendString:@"fi\n"];
    }

    [block appendString:@"\n"];
    [block appendString:@"if [ $avviato -eq 1 ]; then\n"];
    [block appendString:@"    rm -f \"$OUT\" \"$T\"\n"];
    [block appendString:@"    echo VXOST_OK\n"];
    // ⚠️ Non si dichiara riuscito quello che non si e' guardato, e non si
    // torna indietro per un dubbio: Apache e' su, la configurazione ha
    // passato il configtest, e riportarlo giu' sarebbe il danno peggiore.
    // Si dice com'e'.
    [block appendString:@"elif [ $avviato -eq 2 ]; then\n"];
    [block appendString:@"    rm -f \"$OUT\" \"$T\"\n"];
    [block appendString:@"    echo \"NOTE: Apache is running, but the reload could not be verified:\"\n"];
    [block appendString:@"    echo \"the error log is not a readable file (syslog, or a program behind a pipe).\"\n"];
    [block appendString:@"    echo \"Open the site before relying on it.\"\n"];
    [block appendString:@"    echo VXOST_OK_UNVERIFIED\n"];
    [block appendString:@"else\n"];
    [block appendString:@"    # Si torna indietro e si rimette su quello che c'era: il danno\n"];
    [block appendString:@"    # peggiore non e' il progetto mancato, e' Apache giu' per tutti.\n"];
    [block appendString:restore];
    // ⚠️ E il ritorno indietro si verifica come il riavvio: rimettere i file
    // com'erano non serve a niente se poi Apache non risale. Quando non
    // risale, la configurazione su disco e quella caricata non coincidono
    // piu', e chi legge deve saperlo da subito, non dal primo 503.
    [block appendString:@"    prima_rb_m=$(vxost_misura) || prima_rb_m=''\n"];
    [block appendString:@"    prima_rb_s=''; prima_rb_h=''\n"];
    [block appendString:@"    if [ -n \"$prima_rb_m\" ]; then prima_rb_s=${prima_rb_m%% *}; prima_rb_h=${prima_rb_m#* }; fi\n"];
    [block appendString:@"    prima_rb=$(date +%s)\n"];
    [block appendString:@"    \"$CTL\" startapache >/dev/null 2>&1 || true\n"];
    [block appendString:@"    tornato=0\n"];
    [block appendString:@"    attesa=0\n"];
    [block appendString:@"    while [ $attesa -lt 15 ]; do\n"];
    [block appendString:@"        vxost_ripartito \"$prima_rb\" \"$prima_rb_s\" \"$prima_rb_h\"; esito=$?\n"];
    [block appendString:@"        if [ $esito -eq 0 ]; then tornato=1; break; fi\n"];
    [block appendString:@"        if [ $esito -eq 2 ]; then\n"];
    [block appendString:@"            tornato=2\n"];
    [block appendString:@"            [ $attesa -ge 3 ] && break\n"];
    [block appendString:@"        else\n"];
    [block appendString:@"            tornato=0\n"];
    [block appendString:@"        fi\n"];
    [block appendString:@"        sleep 1\n"];
    [block appendString:@"        attesa=$((attesa + 1))\n"];
    [block appendString:@"    done\n"];
    [block appendString:@"    echo \"control script exit status: $ctl\"\n"];
    [block appendString:@"    if [ $tornato -eq 1 ]; then\n"];
    [block appendString:@"        echo \"the previous configuration is back and Apache is serving it\"\n"];
    [block appendString:@"    elif [ $tornato -eq 2 ]; then\n"];
    [block appendString:@"        echo \"the files were restored and Apache is running, but the reload could not be\"\n"];
    [block appendString:@"        echo \"verified: the error log is not a readable file. Open a project page to check.\"\n"];
    [block appendString:@"    else\n"];
    [block appendString:@"        echo \"WARNING: the files were restored but Apache did not come back up.\"\n"];
    [block appendString:@"        echo \"What is on disk and what is running no longer match. Start it by hand:\"\n"];
    [block appendString:@"        echo \"  sudo $CTL startapache\"\n"];
    [block appendString:@"    fi\n"];
    [block appendString:@"    cat \"$OUT\" 2>/dev/null || true\n"];
    [block appendString:@"    rm -f \"$OUT\" \"$T\"\n"];
    [block appendString:@"    echo VXOST_RESTART_FAILED\n"];
    [block appendString:@"fi\n"];
    return block;
}

- (NSString *)privilegedScriptForProject:(NSString *)project
                                 summary:(NSString *)summary
                                 docroot:(NSString *)docroot
                                    port:(NSInteger)port
                              phpVersion:(XPPhpVersion *)phpVersion {

    NSString *root = [XPPaths installRoot];
    NSString *control = [XPPaths controlScript];

    // La descrizione finisce come commento sopra il blocco: e' il posto in cui
    // la si cerca quando si apre il file per capire di chi e' una porta, ed e'
    // l'unico che sopravvive a un backup del solo httpd-vhosts.conf.
    //
    // ⚠️ A capo e cancelletti si tolgono. Una descrizione su due righe
    // spezzerebbe il commento e lascerebbe mezza frase come direttiva, e
    // Apache non ripartirebbe piu'.
    NSString *comment = @"";
    NSString *clean = [(summary ?: @"") stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (clean.length > 0) {
        for (NSString *bad in @[@"\n", @"\r", @"#"]) {
            clean = [clean stringByReplacingOccurrencesOfString:bad withString:@" "];
        }
        if (clean.length > 200) clean = [clean substringToIndex:200];
        comment = [NSString stringWithFormat:@"# %@\n", clean];
    }

    NSString *phpBlock = phpVersion ? [phpVersion virtualHostDirective] : @"";

    // ⚠️ Un progetto nuovo nasce come sta l'installazione, non sempre aperto.
    // Lo scope si legge dai file, e solo la Listen cambia: il VirtualHost
    // resta su `*` di proposito, perche' e' la Listen l'unica direttiva che
    // XPExposure riscrive quando si cambia esposizione. Legando il VirtualHost
    // a 127.0.0.1 il progetto resterebbe irraggiungibile dalla rete anche
    // dopo averla riaperta, e nessuno saprebbe perche'.
    NSString *listenLine =
        [XPExposure listenDirectiveForPort:port scope:[XPExposure currentScope]];

    // Il riavvio verificato, con i comandi che rimettono i file com'erano se
    // Apache non riparte.
    NSString *restart = XPApacheRestartBlock(port,
        @"    cp \"$HTTPD.vxost-$STAMP.bak\"  \"$HTTPD\"\n"
        @"    cp \"$VHOSTS.vxost-$STAMP.bak\" \"$VHOSTS\"\n");

    return [NSString stringWithFormat:
        @"#!/bin/sh\n"
        @"# Generato da VXOST per il progetto %1$@. Si cancella da solo.\n"
        @"set -u\n"
        @"\n"
        @"R='%2$@'\n"
        @"CTL='%3$@'\n"
        @"HTTPD=\"$R/etc/httpd.conf\"\n"
        @"VHOSTS=\"$R/etc/extra/httpd-vhosts.conf\"\n"
        @"STAMP=$(date +%%Y%%m%%d-%%H%%M%%S)\n"
        @"\n"
        @"# Copie prima di toccare qualsiasi cosa. Restano sul disco: sono la\n"
        @"# via di ritorno anche per chi arriva dopo, non solo per questo script.\n"
        @"cp \"$HTTPD\"  \"$HTTPD.vxost-$STAMP.bak\"  || { echo VXOST_BACKUP_FAILED; exit 0; }\n"
        @"cp \"$VHOSTS\" \"$VHOSTS.vxost-$STAMP.bak\" || { echo VXOST_BACKUP_FAILED; exit 0; }\n"
        @"\n"
        @"cat >> \"$HTTPD\" <<'VXOST_EOF_LISTEN'\n"
        @"\n"
        @"# VXOST wizard: %1$@\n"
        @"%9$@\n"
        @"VXOST_EOF_LISTEN\n"
        @"\n"
        @"cat >> \"$VHOSTS\" <<'VXOST_EOF_VHOST'\n"
        @"\n"
        @"# VXOST wizard: %1$@\n"
        @"%7$@"
        @"<VirtualHost *:%4$ld>\n"
        @"    DocumentRoot \"%5$@\"\n"
        @"    ServerName %6$@\n"
        @"    <Directory \"%5$@\">\n"
        @"        Options Indexes FollowSymLinks\n"
        @"        AllowOverride All\n"
        @"        Require all granted\n"
        @"    </Directory>\n"
        @"    ErrorLog \"logs/%1$@-error_log\"\n"
        @"    CustomLog \"logs/%1$@-access_log\" common\n"
        @"%8$@"
        @"</VirtualHost>\n"
        @"VXOST_EOF_VHOST\n"
        @"\n"
        @"# Il controllo prima del riavvio: una configurazione malformata non\n"
        @"# lascerebbe giù solo il progetto nuovo, ma tutti quelli che ci sono.\n"
        @"if \"$R/bin/httpd\" -t -d \"$R\" -f \"$HTTPD\" 2>&1 | grep -qi 'Syntax OK'; then\n"
        @"%10$@"
        @"else\n"
        @"    cp \"$HTTPD.vxost-$STAMP.bak\"  \"$HTTPD\"\n"
        @"    cp \"$VHOSTS.vxost-$STAMP.bak\" \"$VHOSTS\"\n"
        @"    echo VXOST_CONFIGTEST_FAILED\n"
        @"fi\n"
        @"exit 0\n",
        project, root, control, (long)port, docroot, [XPPaths localHostname],
        comment, phpBlock, listenLine, restart];
}

#pragma mark - Messaggi

#pragma mark - Versione di PHP di un progetto

- (void)setPhpVersion:(XPPhpVersion *)version
              forHost:(XPVirtualHost *)host
           completion:(void (^)(BOOL ok))completion {

    if (!host || host.port <= 0) {
        if (completion) completion(NO);
        return;
    }
    if (host.state == XPVHostStateDisabled) {
        [self postMessage:NSLocalizedString(@"php.err.disabled", nil) isError:YES];
        if (completion) completion(NO);
        return;
    }

    NSString *vhosts = [XPPaths root:@"etc/extra/httpd-vhosts.conf"];
    NSString *text = [NSString stringWithContentsOfFile:vhosts
                                               encoding:NSUTF8StringEncoding
                                                  error:NULL];
    if (!text) {
        [self postMessage:NSLocalizedString(@"wizard.failed.backup", nil) isError:YES];
        if (completion) completion(NO);
        return;
    }

    NSString *directive = version ? [version virtualHostDirective] : @"";
    NSString *rewritten = [XPVirtualHost configuration:text
                                            settingPhp:directive
                                               forPort:host.port];
    if (!rewritten) {
        [self postMessage:NSLocalizedString(@"php.done.nochange", nil) isError:NO];
        if (completion) completion(YES);
        return;
    }

    [self postMessage:NSLocalizedString(@"php.progress.pool", nil) isError:NO];

    // ⚠️ Prima il pool, poi il virtual host. Scrivendo il virtual host per
    // primo, Apache riparte puntando a un socket che non esiste e il progetto
    // risponde 503 finché qualcuno non accende il pool: un errore che sembra
    // un guasto e invece è un ordine sbagliato.
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *poolProblem = version ? [version startPool] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            if (poolProblem) {
                [self postMessage:poolProblem isError:YES];
                if (completion) completion(NO);
                return;
            }

            NSString *temporary = [NSTemporaryDirectory() stringByAppendingPathComponent:
                [NSString stringWithFormat:@"vxost-vhosts-%@.conf", [NSUUID UUID].UUIDString]];
            if (![rewritten writeToFile:temporary atomically:YES
                               encoding:NSUTF8StringEncoding error:NULL]) {
                [self postMessage:NSLocalizedString(@"wizard.failed.backup", nil) isError:YES];
                if (completion) completion(NO);
                return;
            }

            NSString *done = [NSString stringWithFormat:
                NSLocalizedString(@"php.done", nil), host.name ?: @"",
                version ? version.description : NSLocalizedString(@"php.bundled", nil)];

            [self replaceConfiguration:@{vhosts: temporary}
                              progress:NSLocalizedString(@"wizard.progress.vhost", nil)
                               success:done
                            completion:^(BOOL ok) {
                [[NSFileManager defaultManager] removeItemAtPath:temporary error:NULL];
                if (completion) completion(ok);
            }];
        });
    });
}

#pragma mark - Scrittura protetta della configurazione

/// Lo script che mette i file preparati al posto di quelli veri.
///
/// Esposto a sé stante perché è la parte che si può provare senza toccare
/// niente: si guarda cosa scrive, invece di eseguirlo e vedere cosa succede.
- (NSString *)configurationScriptFor:(NSDictionary<NSString *, NSString *> *)staged {
    NSString *root = [XPPaths installRoot];
    NSString *control = [XPPaths controlScript];

    NSMutableString *script = [NSMutableString string];
    [script appendString:@"#!/bin/sh\n"];
    [script appendString:@"# Generato da VXOST. Si cancella da solo.\n"];
    [script appendString:@"set -u\n\n"];
    [script appendFormat:@"R='%@'\n", root];
    [script appendFormat:@"CTL='%@'\n", control];
    [script appendString:@"HTTPD=\"$R/etc/httpd.conf\"\n"];
    [script appendString:@"STAMP=$(date +%Y%m%d-%H%M%S)\n\n"];

    // 🔴 Ogni percorso passa da una variabile di shell, e non finisce dentro
    // il nome del backup a mano.
    //
    // La prima versione scriveva:
    //     cp '/percorso/httpd.conf' '/percorso/httpd.conf.vxost-$STAMP.bak'
    // e dentro gli apici singoli la shell NON espande le variabili: il backup
    // si chiamava letteralmente "httpd.conf.vxost-$STAMP.bak". Non un errore
    // visibile — il ripristino funzionava, perché rileggeva lo stesso nome
    // sbagliato — ma un file solo invece di uno per volta, sovrascritto a ogni
    // operazione. La rete di sicurezza teneva una maglia sola.
    //
    // Gli apici singoli servono comunque, sul percorso: è dato che arriva da
    // fuori dalla shell. Quindi si assegna una volta fra apici singoli, e da lì
    // in poi si usa fra apici doppi, dove $STAMP si espande.
    NSArray<NSString *> *sources = [staged.allKeys sortedArrayUsingSelector:@selector(compare:)];
    for (NSUInteger i = 0; i < sources.count; i++) {
        [script appendFormat:@"F%lu='%@'\n", (unsigned long)i, sources[i]];
        [script appendFormat:@"N%lu='%@'\n", (unsigned long)i, staged[sources[i]]];
    }
    [script appendString:@"\n"];

    // Le copie restano sul disco: sono la via di ritorno anche per chi arriva
    // dopo, non solo per questo script.
    for (NSUInteger i = 0; i < sources.count; i++) {
        [script appendFormat:
         @"cp \"$F%lu\" \"$F%lu.vxost-$STAMP.bak\" || { echo VXOST_BACKUP_FAILED; exit 0; }\n",
         (unsigned long)i, (unsigned long)i];
    }
    [script appendString:@"\n"];
    for (NSUInteger i = 0; i < sources.count; i++) {
        [script appendFormat:@"cat \"$N%lu\" > \"$F%lu\"\n",
         (unsigned long)i, (unsigned long)i];
    }

    [script appendString:@"\n# Il controllo prima del riavvio: una configurazione malformata non\n"];
    [script appendString:@"# lascerebbe giu' un progetto, li lascerebbe giu' tutti.\n"];
    // I comandi che rimettono i file com'erano servono in due rami: se la
    // sintassi non passa, e se Apache non riparte lo stesso. Si scrivono una
    // volta sola, perche' due elenchi di ripristino divergono al primo file
    // aggiunto e il secondo ramo ne rimetterebbe indietro solo una parte.
    NSMutableString *restore = [NSMutableString string];
    for (NSUInteger i = 0; i < sources.count; i++) {
        [restore appendFormat:@"    cp \"$F%lu.vxost-$STAMP.bak\" \"$F%lu\"\n",
         (unsigned long)i, (unsigned long)i];
    }

    [script appendString:@"if \"$R/bin/httpd\" -t -d \"$R\" -f \"$HTTPD\" 2>&1 | grep -qi 'Syntax OK'; then\n"];
    // Qui la porta non si conosce: si riscrivono file di configurazione, non
    // si crea un progetto. Il controllo si ferma al pid, che e' comunque
    // quello che manca quando Apache non riparte.
    [script appendString:XPApacheRestartBlock(0, restore)];
    [script appendString:@"else\n"];
    [script appendString:restore];
    [script appendString:@"    echo VXOST_CONFIGTEST_FAILED\n"];
    [script appendString:@"fi\n"];
    // ⚠️ Esce sempre con 0: `do shell script` trasforma un'uscita diversa da
    // zero in un errore AppleScript e il codice vero non arriverebbe mai qui.
    [script appendString:@"exit 0\n"];


    return script;
}

- (void)replaceConfiguration:(NSDictionary<NSString *, NSString *> *)staged
                    progress:(NSString *)progress
                     success:(NSString *)success
                  completion:(void (^)(BOOL ok))completion {

    if (staged.count == 0) {
        if (completion) completion(YES);
        return;
    }

    NSString *script = [self configurationScriptFor:staged];

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *scriptPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"vxost-config-%@.sh", [NSUUID UUID].UUIDString]];
    if (![script writeToFile:scriptPath atomically:YES
                    encoding:NSUTF8StringEncoding error:NULL]) {
        [self postMessage:NSLocalizedString(@"wizard.failed.backup", nil) isError:YES];
        if (completion) completion(NO);
        return;
    }
    [fm setAttributes:@{NSFilePosixPermissions: @(0700)} ofItemAtPath:scriptPath error:NULL];

    if (progress.length > 0) [self postMessage:progress isError:NO];

    [XPTaskRunner runPrivilegedShell:[NSString stringWithFormat:@"/bin/sh '%@'", scriptPath]
                          completion:^(XPTaskResult *result) {
        [fm removeItemAtPath:scriptPath error:NULL];

        BOOL ok = NO;
        NSString *message;
        if (result.cancelled) {
            message = NSLocalizedString(@"msg.cancelled", nil);
        } else if ([result.output containsString:@"VXOST_BACKUP_FAILED"]) {
            message = NSLocalizedString(@"wizard.failed.backup", nil);
        } else if ([result.output containsString:@"VXOST_CONFIGTEST_FAILED"]) {
            message = NSLocalizedString(@"wizard.failed.configtest", nil);
        } else if ([result.output containsString:@"VXOST_RESTART_FAILED"]) {
            message = NSLocalizedString(@"wizard.failed.restart", nil);
        // ⚠️ Prima di VXOST_OK, perche' containsString: lo trova anche dentro
        // VXOST_OK_UNVERIFIED: invertendo i due rami, un riavvio non
        // verificato passerebbe per verificato senza che niente lo dica.
        //
        // Il messaggio qui non e' tradotto, ed e' voluto: dice cosa non si e'
        // potuto verificare, e una frase tradotta che dichiari il successo
        // sarebbe una bugia in quindici lingue invece che in una.
        } else if ([result.output containsString:@"VXOST_OK_UNVERIFIED"]) {
            ok = YES;
            message = [self firstMeaningfulLine:result.output];
        } else if ([result.output containsString:@"VXOST_OK"]) {
            ok = YES;
            message = success;
        } else {
            message = [self firstMeaningfulLine:result.output];
        }

        [self postMessage:message isError:!ok];
        [[XPServiceMonitor shared] refreshNow];
        if (completion) completion(ok);
    }];
}

- (void)postMessage:(NSString *)message isError:(BOOL)isError {
    [[NSNotificationCenter defaultCenter] postNotificationName:XPActionMessageNotification
                                                        object:self
                                                      userInfo:@{@"message": message ?: @"",
                                                                 @"isError": @(isError)}];
}

@end
