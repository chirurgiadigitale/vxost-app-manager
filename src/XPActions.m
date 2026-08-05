//
//  XPActions.m
//

#import "XPActions.h"
#import "XPPaths.h"
#import "XPServiceMonitor.h"
#import "XPTaskRunner.h"

NSString *const XPActionMessageNotification = @"XPActionMessageNotification";

@implementation XPActions

+ (instancetype)shared {
    static XPActions *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[XPActions alloc] init]; });
    return shared;
}

#pragma mark - Esecuzione

/// Esegue un'azione dello script xampp marcando i servizi come "in transizione".
- (void)performAction:(NSString *)action
           onServices:(NSArray<XPService *> *)services
          description:(NSString *)description {

    for (XPService *service in services) service.state = XPServiceStateBusy;
    [[NSNotificationCenter defaultCenter] postNotificationName:XPServicesDidChangeNotification
                                                        object:self];
    [self postMessage:[NSString stringWithFormat:@"%@…", description] isError:NO];

    [XPTaskRunner runPrivilegedXamppAction:action completion:^(XPTaskResult *result) {
        // Lo stato torna a essere dedotto dai processi reali.
        for (XPService *service in services) service.state = XPServiceStateStopped;

        if (result.cancelled) {
            [self postMessage:@"Operazione annullata" isError:NO];
        } else if (!result.succeeded) {
            [self postMessage:[self firstMeaningfulLine:result.output] isError:YES];
        } else {
            [self postMessage:[NSString stringWithFormat:@"%@: fatto", description] isError:NO];
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
    return @"Comando fallito";
}

#pragma mark - Servizi

- (void)toggleService:(XPService *)service {
    BOOL running = (service.state == XPServiceStateRunning);
    NSString *action = running ? service.stopAction : service.startAction;
    NSString *description = [NSString stringWithFormat:@"%@ di %@",
                             running ? @"Arresto" : @"Avvio", service.name];
    [self performAction:action onServices:@[service] description:description];
}

- (void)reloadService:(XPService *)service {
    [self performAction:service.reloadAction
             onServices:@[service]
            description:[NSString stringWithFormat:@"Ricarica di %@", service.name]];
}

- (void)startAll {
    [self performAction:@"start"
             onServices:[XPServiceMonitor shared].services
            description:@"Avvio dei servizi"];
}

- (void)stopAll {
    [self performAction:@"stop"
             onServices:[XPServiceMonitor shared].services
            description:@"Arresto dei servizi"];
}

- (void)restartAll {
    [self performAction:@"restart"
             onServices:[XPServiceMonitor shared].services
            description:@"Riavvio dei servizi"];
}

#pragma mark - Collegamenti

- (void)openDashboard {
    [self openURLString:@"http://localhost/dashboard/"];
}

- (void)openPhpMyAdmin {
    [self openURLString:@"http://localhost/phpmyadmin/"];
}

- (void)openURLString:(NSString *)urlString {
    // Con Apache fermo il browser mostrerebbe soltanto un errore di
    // connessione: meglio dirlo prima di aprirlo.
    XPService *apache = [[XPServiceMonitor shared] serviceForKey:@"apache"];
    if (apache.state != XPServiceStateRunning) {
        [self postMessage:@"Apache è fermo: avvialo per aprire questa pagina" isError:YES];
        return;
    }
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:urlString]];
}

- (void)openHtdocs {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:[XPPaths htdocs]]];
}

- (void)openXamppFolder {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:XPRoot]];
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
                 message:@"Abilitare il supporto SSL di Apache? Apache verrà riavviato."
             description:@"Abilitazione SSL"];
}

- (void)disableSSL {
    [self confirmThenRun:@"disablessl"
                 message:@"Disabilitare il supporto SSL di Apache? Apache verrà riavviato."
             description:@"Disabilitazione SSL"];
}

- (void)confirmThenRun:(NSString *)action
               message:(NSString *)message
           description:(NSString *)description {

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Confermi l'operazione?";
    alert.informativeText = message;
    [alert addButtonWithTitle:@"Procedi"];
    [alert addButtonWithTitle:@"Annulla"];
    alert.alertStyle = NSAlertStyleWarning;

    [NSApp activateIgnoringOtherApps:YES];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;

    [self performAction:action
             onServices:[XPServiceMonitor shared].services
            description:description];
}

- (void)runSecurityCheck { [self runInTerminal:@"security"]; }
- (void)runBackup        { [self runInTerminal:@"backup"]; }

/// Apre il Terminale sul comando indicato: `security` e `backup` fanno domande
/// e in esecuzione silenziosa resterebbero appesi in attesa di risposta.
- (void)runInTerminal:(NSString *)action {
    NSString *command = [NSString stringWithFormat:@"sudo '%@' %@", XPControlScript, action];
    NSString *source = [NSString stringWithFormat:
        @"tell application \"Terminal\"\n"
        @"  activate\n"
        @"  do script \"%@\"\n"
        @"end tell", command];

    NSAppleScript *script = [[NSAppleScript alloc] initWithSource:source];
    NSDictionary *error = nil;
    [script executeAndReturnError:&error];
    if (error) {
        [self postMessage:@"Impossibile aprire il Terminale" isError:YES];
    } else {
        [self postMessage:@"Comando aperto nel Terminale" isError:NO];
    }
}

#pragma mark - Messaggi

- (void)postMessage:(NSString *)message isError:(BOOL)isError {
    [[NSNotificationCenter defaultCenter] postNotificationName:XPActionMessageNotification
                                                        object:self
                                                      userInfo:@{@"message": message ?: @"",
                                                                 @"isError": @(isError)}];
}

@end
