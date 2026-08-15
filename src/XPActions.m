//
//  XPActions.m
//

#import "XPActions.h"
#import "XPPaths.h"
#import "XPServiceMonitor.h"
#import "XPTaskRunner.h"
#import "XPDatabase.h"
#import "XPPhpVersion.h"

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
        @"Listen %4$ld\n"
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
        @"    if pgrep -x httpd >/dev/null 2>&1; then\n"
        @"        \"$CTL\" restartapache >/dev/null 2>&1\n"
        @"    else\n"
        @"        \"$CTL\" startapache >/dev/null 2>&1\n"
        @"    fi\n"
        @"    echo VXOST_OK\n"
        @"else\n"
        @"    cp \"$HTTPD.vxost-$STAMP.bak\"  \"$HTTPD\"\n"
        @"    cp \"$VHOSTS.vxost-$STAMP.bak\" \"$VHOSTS\"\n"
        @"    echo VXOST_CONFIGTEST_FAILED\n"
        @"fi\n"
        @"exit 0\n",
        project, root, control, (long)port, docroot, [XPPaths localHostname],
        comment, phpBlock];
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
    [script appendString:@"if \"$R/bin/httpd\" -t -d \"$R\" -f \"$HTTPD\" 2>&1 | grep -qi 'Syntax OK'; then\n"];
    [script appendString:@"    if pgrep -x httpd >/dev/null 2>&1; then\n"];
    [script appendString:@"        \"$CTL\" restartapache >/dev/null 2>&1\n"];
    [script appendString:@"    else\n"];
    [script appendString:@"        \"$CTL\" startapache >/dev/null 2>&1\n"];
    [script appendString:@"    fi\n"];
    [script appendString:@"    echo VXOST_OK\n"];
    [script appendString:@"else\n"];
    for (NSUInteger i = 0; i < sources.count; i++) {
        [script appendFormat:@"    cp \"$F%lu.vxost-$STAMP.bak\" \"$F%lu\"\n",
         (unsigned long)i, (unsigned long)i];
    }
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
