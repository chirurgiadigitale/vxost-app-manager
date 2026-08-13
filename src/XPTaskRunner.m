//
//  XPTaskRunner.m
//

#import "XPTaskRunner.h"
#import "XPPaths.h"

@implementation XPTaskResult
- (BOOL)succeeded { return self.status == 0 && !self.cancelled; }
@end


@implementation XPTaskRunner

#pragma mark - Esecuzione non privilegiata

+ (XPTaskResult *)run:(NSString *)launchPath arguments:(NSArray<NSString *> *)arguments {
    XPTaskResult *result = [[XPTaskResult alloc] init];

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:launchPath];
    task.arguments = arguments ?: @[];

    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError  = pipe;

    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        result.status = -1;
        result.output = error.localizedDescription ?: @"Impossibile avviare il processo";
        return result;
    }

    // Legge fino a EOF prima di attendere: evita il deadlock del buffer pieno
    // sui comandi con output lungo.
    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];

    result.status = task.terminationStatus;
    result.output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
    return result;
}

#pragma mark - Esecuzione privilegiata

/// Rende una stringa sicura dentro un literal AppleScript.
static NSString *EscapeForAppleScript(NSString *s) {
    NSString *escaped = [s stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    return [escaped stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
}

+ (void)runPrivilegedVxostAction:(NSString *)action
                      completion:(void (^)(XPTaskResult *))completion {
    // Il percorso dello script si chiede a XPPaths, che lo rileva a runtime.
    // ⚠️ Scriverlo in duro qui è già costato un pomeriggio: l'app puntava a
    // /Applications/VXOST/vxostfiles/vxost su una macchina che ha ancora la
    // cartella vecchia, e ogni avvio o arresto falliva senza dire perché.
    //
    // L'azione arriva sempre da una costante interna dell'app, mai da input
    // dell'utente; il quoting del percorso protegge comunque da spazi.
    NSString *command = [NSString stringWithFormat:@"'%@' %@", [XPPaths controlScript], action];
    [self runPrivilegedShell:command completion:completion];
}

+ (void)runPrivilegedShell:(NSString *)shellCommand
                completion:(void (^)(XPTaskResult *))completion {

    NSString *script = [NSString stringWithFormat:
        @"do shell script \"%@\" with administrator privileges",
        EscapeForAppleScript(shellCommand)];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        XPTaskResult *result = [self run:@"/usr/bin/osascript" arguments:@[@"-e", script]];

        // osascript esce con codice 1 e "User canceled" se l'utente chiude il
        // pannello password: non è un errore, va distinto.
        if (result.status != 0) {
            NSString *lower = result.output.lowercaseString;
            if ([lower containsString:@"user canceled"] || [lower containsString:@"-128"]) {
                result.cancelled = YES;
            }
        }

        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
        }
    });
}

@end
