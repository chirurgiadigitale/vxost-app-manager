//
//  scripttest.m
//  Lo script che sostituisce i file di configurazione di Apache: si guarda
//  cosa scrive, e la parte delle copie si esegue davvero su file finti.
//
//  ⚠️ Non tocca l'installazione. I file su cui lavora stanno in una cartella
//  temporanea, e le righe che riavviano Apache non vengono mai eseguite.
//
//  Questo file esiste per un difetto trovato il 15/08: il backup si chiamava
//  letteralmente "httpd.conf.vxost-$STAMP.bak", perché dentro gli apici
//  singoli la shell non espande le variabili. Non dava errore, il ripristino
//  funzionava lo stesso, e la rete di sicurezza teneva una maglia sola: un
//  backup, sovrascritto a ogni operazione, invece di uno per volta.
//

#import <Cocoa/Cocoa.h>
#import "XPActions.h"

@interface XPActions (Test)
- (NSString *)configurationScriptFor:(NSDictionary<NSString *, NSString *> *)staged;
@end

static int P = 0, F = 0;
static void check(BOOL c, NSString *w) {
    if (c) { P++; printf("  \033[32m✓\033[0m %s\n", w.UTF8String); }
    else   { F++; printf("  \033[31m✗ %s\033[0m\n", w.UTF8String); }
}
static void section(NSString *t) { printf("\n\033[1m%s\033[0m\n", t.UTF8String); }

/// Esegue un pezzo di shell e restituisce l'uscita.
static NSString *runShell(NSString *script) {
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
                      @"vxost-scripttest-run.sh"];
    [script writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];

    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/bin/sh";
    task.arguments = @[path];
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = pipe;
    [task launch];
    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

int main(void) { @autoreleasepool {
    printf("\n\033[1mLo script che scrive la configurazione\033[0m\n");

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *sandbox = [NSTemporaryDirectory() stringByAppendingPathComponent:
                         [@"vxost-scripttest-" stringByAppendingString:[NSUUID UUID].UUIDString]];
    [fm createDirectoryAtPath:sandbox withIntermediateDirectories:YES
                   attributes:nil error:NULL];

    NSString *live = [sandbox stringByAppendingPathComponent:@"httpd.conf"];
    NSString *live2 = [sandbox stringByAppendingPathComponent:@"httpd-ssl.conf"];
    NSString *fresh = [sandbox stringByAppendingPathComponent:@"nuovo.conf"];
    NSString *fresh2 = [sandbox stringByAppendingPathComponent:@"nuovo2.conf"];
    [@"vecchio 1\n" writeToFile:live atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    [@"vecchio 2\n" writeToFile:live2 atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    [@"nuovo 1\n" writeToFile:fresh atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    [@"nuovo 2\n" writeToFile:fresh2 atomically:YES encoding:NSUTF8StringEncoding error:NULL];

    NSString *script = [[XPActions shared] configurationScriptFor:
                        @{live: fresh, live2: fresh2}];

    section(@"Come è scritto");
    check(script.length > 0, @"lo script c'è");
    check([script containsString:@"STAMP=$(date"], @"la data si calcola nello script");
    check([script containsString:@"VXOST_BACKUP_FAILED"], @"prevede il backup fallito");
    check([script containsString:@"VXOST_CONFIGTEST_FAILED"], @"prevede il configtest fallito");
    check([script containsString:@"VXOST_OK"], @"dice quando è andata");
    check([script hasSuffix:@"exit 0\n"], @"esce sempre con 0");
    check([script containsString:@"-t -d"], @"valida prima di riavviare");

    // ⛔ Il difetto del 15/08: $STAMP dentro apici singoli non si espande.
    check(![script containsString:@"'.vxost-$STAMP"],
          @"il nome del backup non sta fra apici singoli");
    check([script containsString:@".vxost-$STAMP.bak\""],
          @"il nome del backup sta fra apici doppi, dove $STAMP si espande");

    section(@"Sintassi");
    NSString *syntaxPath = [sandbox stringByAppendingPathComponent:@"s.sh"];
    [script writeToFile:syntaxPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    NSTask *syntax = [[NSTask alloc] init];
    syntax.launchPath = @"/bin/sh";
    syntax.arguments = @[@"-n", syntaxPath];
    syntax.standardOutput = [NSPipe pipe];
    syntax.standardError = syntax.standardOutput;
    [syntax launch];
    [syntax waitUntilExit];
    check(syntax.terminationStatus == 0, @"è shell valida (sh -n)");

    section(@"Le copie, eseguite davvero");
    // Si prende solo la parte che tocca i file: assegnazioni, STAMP e le cp.
    // Le righe che riavviano Apache non entrano, per ovvi motivi.
    //
    // ⚠️ La riga si guarda **senza toglierle gli spazi davanti**, ed è il
    // punto in cui questo test si è sbagliato la prima volta. Le copie del
    // ripristino, dentro il ramo `else`, sono rientrate di quattro spazi:
    // togliendo gli spazi cominciano anche loro con `cp "`, entravano nel
    // pezzo da eseguire e rimettevano indietro il vecchio un istante dopo
    // averlo sostituito. Il risultato sembrava un difetto del codice.
    NSMutableString *safe = [NSMutableString string];
    for (NSString *line in [script componentsSeparatedByString:@"\n"]) {
        if ([line hasPrefix:@"F"] || [line hasPrefix:@"N"] ||
            [line hasPrefix:@"STAMP="] ||
            [line hasPrefix:@"cp \""] || [line hasPrefix:@"cat \""]) {
            [safe appendFormat:@"%@\n", line];
        }
    }
    NSString *output = runShell(safe);
    check(output.length == 0, @"le copie girano senza dire niente");

    NSArray *left = [fm contentsOfDirectoryAtPath:sandbox error:NULL];
    NSMutableArray *backups = [NSMutableArray array];
    for (NSString *name in left) if ([name hasSuffix:@".bak"]) [backups addObject:name];
    [backups sortUsingSelector:@selector(compare:)];

    for (NSString *name in backups) printf("      %s\n", name.UTF8String);
    check(backups.count == 2, @"un backup per file, non uno solo");

    BOOL literal = NO;
    for (NSString *name in backups) if ([name containsString:@"$STAMP"]) literal = YES;
    check(!literal, @"nessun backup si chiama letteralmente $STAMP");

    // La data deve essere una data: otto cifre, un trattino, sei cifre.
    NSRegularExpression *dated = [NSRegularExpression regularExpressionWithPattern:
                                  @"\\.vxost-\\d{8}-\\d{6}\\.bak$" options:0 error:NULL];
    NSUInteger withDate = 0;
    for (NSString *name in backups) {
        withDate += [dated numberOfMatchesInString:name options:0
                                              range:NSMakeRange(0, name.length)];
    }
    check(withDate == backups.count, @"ogni backup porta la data nel nome");

    // E il contenuto: il backup ha il vecchio, il file vero ha il nuovo.
    NSString *now = [NSString stringWithContentsOfFile:live
                                              encoding:NSUTF8StringEncoding error:NULL];
    check([now isEqualToString:@"nuovo 1\n"], @"il file vero è stato sostituito");
    NSString *saved = nil;
    for (NSString *name in backups) {
        if ([name hasPrefix:@"httpd.conf.vxost-"]) {
            saved = [NSString stringWithContentsOfFile:
                     [sandbox stringByAppendingPathComponent:name]
                                              encoding:NSUTF8StringEncoding error:NULL];
        }
    }
    check([saved isEqualToString:@"vecchio 1\n"], @"il backup contiene il vecchio");

    [fm removeItemAtPath:sandbox error:NULL];
    printf("\n\033[1m%d passati, %d falliti\033[0m\n\n", P, F);
    return F == 0 ? 0 : 1;
}}
