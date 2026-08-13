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
        [self postMessage:NSLocalizedString(@"msg.terminalFailed", nil) isError:YES];
    } else {
        [self postMessage:NSLocalizedString(@"msg.terminalOpened", nil) isError:NO];
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
