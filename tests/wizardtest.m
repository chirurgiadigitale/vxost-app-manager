//
//  wizardtest.m
//  Esercita il wizard senza aprire interfacce: nome del database, versioni di
//  PHP, e lo script privilegiato che il wizard fa girare come root.
//
//  ⚠️ Non crea niente. Non tocca httpd-vhosts.conf, non parla con MySQL per
//  scrivere: legge e basta. Lo script generato finisce in un file temporaneo e
//  ci si passa `sh -n` sopra, che controlla la sintassi senza eseguirlo.
//

#import <Cocoa/Cocoa.h>
#import "XPActions.h"
#import "XPDatabase.h"
#import "XPPhpVersion.h"
#import "XPPaths.h"

/// I metodi che il wizard usa e che l'intestazione non pubblica.
@interface XPActions (Test)
- (NSString *)privilegedScriptForProject:(NSString *)project
                                 summary:(NSString *)summary
                                 docroot:(NSString *)docroot
                                    port:(NSInteger)port
                              phpVersion:(XPPhpVersion *)phpVersion;
@end

static int sPassed = 0;
static int sFailed = 0;

static void check(BOOL condition, NSString *what) {
    if (condition) {
        sPassed++;
        printf("  \033[32m✓\033[0m %s\n", what.UTF8String);
    } else {
        sFailed++;
        printf("  \033[31m✗ %s\033[0m\n", what.UTF8String);
    }
}

static void section(NSString *title) {
    printf("\n\033[1m%s\033[0m\n", title.UTF8String);
}

/// Scrive lo script e chiede a sh se è sintatticamente valido.
static BOOL scriptIsValidShell(NSString *script) {
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
                      @"vxost-wizardtest.sh"];
    if (![script writeToFile:path atomically:YES
                    encoding:NSUTF8StringEncoding error:NULL]) return NO;

    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/bin/sh";
    task.arguments = @[@"-n", path];
    task.standardOutput = [NSPipe pipe];
    task.standardError = task.standardOutput;
    [task launch];
    [task waitUntilExit];
    int status = task.terminationStatus;
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
    return status == 0;
}

int main(void) { @autoreleasepool {
    printf("\n\033[1mWizard: descrizione, PHP, database\033[0m\n");

    // ---------------------------------------------------------------- nomi
    section(@"Nome del database");
    check([XPDatabase validationErrorForDatabaseName:@"my_project"] == nil,
          @"my_project va bene");
    check([XPDatabase validationErrorForDatabaseName:@"wp2"] == nil,
          @"wp2 va bene");
    check([XPDatabase validationErrorForDatabaseName:@""] != nil,
          @"vuoto rifiutato");
    check([XPDatabase validationErrorForDatabaseName:@"2wp"] != nil,
          @"non può iniziare con una cifra");
    check([XPDatabase validationErrorForDatabaseName:@"my-project"] != nil,
          @"il trattino è rifiutato");
    check([XPDatabase validationErrorForDatabaseName:@"My_Project"] != nil,
          @"le maiuscole sono rifiutate");
    check([XPDatabase validationErrorForDatabaseName:@"drop`; DROP DATABASE x"] != nil,
          @"un nome con apici e spazi è rifiutato");
    check([XPDatabase validationErrorForDatabaseName:
           @"abcdefghijklmnopqrstuvwxyz1234567890"] != nil,
          @"oltre 32 caratteri è rifiutato");

    // ----------------------------------------------------------------- php
    section(@"Versioni di PHP");
    NSArray<XPPhpVersion *> *versions = [XPPhpVersion available];
    check(versions.count > 0, @"almeno una versione trovata");
    for (XPPhpVersion *version in versions) {
        printf("      %s\n", version.description.UTF8String);
    }
    XPPhpVersion *bundled = versions.firstObject;
    check(bundled.isBundled, @"la prima è quella dello stack");
    check([[bundled virtualHostDirective] isEqualToString:@""],
          @"quella dello stack non aggiunge direttive");

    XPPhpVersion *external = nil;
    for (XPPhpVersion *version in versions) {
        if (!version.isBundled) { external = version; break; }
    }
    if (external) {
        NSString *directive = [external virtualHostDirective];
        check([directive containsString:@"SetHandler"], @"le altre usano SetHandler");
        check([directive containsString:@"/tmp/vxost-php"],
              @"il socket sta in /tmp, non nella temp dell'utente");
        check([directive hasSuffix:@"\n"], @"la direttiva finisce con un a capo");
    } else {
        printf("      (nessuna versione esterna installata: due controlli saltati)\n");
    }

    // -------------------------------------------------------------- script
    section(@"Script privilegiato");
    XPActions *actions = [XPActions shared];

    NSString *plain = [actions privilegedScriptForProject:@"demo"
                                                  summary:@""
                                                  docroot:@"/tmp/demo"
                                                     port:4321
                                               phpVersion:bundled];
    check(scriptIsValidShell(plain), @"senza descrizione è shell valida");
    check(![plain containsString:@"localhost"], @"non nomina localhost");
    check([plain containsString:@"ServerName "], @"scrive un ServerName");
    check([plain containsString:@"Listen 4321"], @"apre la porta in httpd.conf");
    check([plain containsString:@"<VirtualHost *:4321>"], @"scrive il blocco");

    NSString *described = [actions privilegedScriptForProject:@"demo"
                                                      summary:@"Sito del cliente Rossi"
                                                      docroot:@"/tmp/demo"
                                                         port:4321
                                                   phpVersion:bundled];
    check(scriptIsValidShell(described), @"con descrizione è shell valida");
    check([described containsString:@"# Sito del cliente Rossi\n<VirtualHost"],
          @"la descrizione sta sopra il blocco, come commento");

    // ⚠️ Il caso che rompe Apache: una descrizione su due righe spezzerebbe il
    // commento e lascerebbe la seconda metà come direttiva.
    NSString *multiline = [actions privilegedScriptForProject:@"demo"
                                                      summary:@"prima riga\nRequire all denied"
                                                      docroot:@"/tmp/demo"
                                                         port:4321
                                                   phpVersion:bundled];
    check(scriptIsValidShell(multiline), @"con descrizione su più righe è shell valida");
    check([multiline containsString:@"# prima riga Require all denied\n<VirtualHost"],
          @"gli a capo diventano spazi e resta un commento solo");
    check(![multiline containsString:@"\nRequire all denied"],
          @"la seconda riga non finisce fuori dal commento");

    NSString *hashed = [actions privilegedScriptForProject:@"demo"
                                                   summary:@"#1 del cliente"
                                                   docroot:@"/tmp/demo"
                                                      port:4321
                                                phpVersion:bundled];
    check([hashed containsString:@"#  1 del cliente\n"],
          @"il cancelletto nel testo diventa uno spazio");

    NSString *longSummary = [@"" stringByPaddingToLength:400
                                              withString:@"a" startingAtIndex:0];
    NSString *truncated = [actions privilegedScriptForProject:@"demo"
                                                      summary:longSummary
                                                      docroot:@"/tmp/demo"
                                                         port:4321
                                                   phpVersion:bundled];
    check(scriptIsValidShell(truncated), @"con descrizione lunghissima è shell valida");
    check(![truncated containsString:[@"" stringByPaddingToLength:220
                                                       withString:@"a" startingAtIndex:0]],
          @"la descrizione viene tagliata a 200 caratteri");

    if (external) {
        NSString *withPhp = [actions privilegedScriptForProject:@"demo"
                                                        summary:@"con php scelto"
                                                        docroot:@"/tmp/demo"
                                                           port:4321
                                                     phpVersion:external];
        check(scriptIsValidShell(withPhp), @"con una versione di PHP è shell valida");
        check([withPhp containsString:@"SetHandler"], @"il blocco PHP c'è");
        // Deve stare dentro il virtual host, non dopo: fuori, Apache lo
        // applicherebbe a tutto il server.
        NSRange handler = [withPhp rangeOfString:@"SetHandler"];
        NSRange close = [withPhp rangeOfString:@"</VirtualHost>"];
        check(handler.location < close.location, @"il blocco PHP sta dentro il vhost");
    }

    NSString *noPhp = [actions privilegedScriptForProject:@"demo"
                                                  summary:@""
                                                  docroot:@"/tmp/demo"
                                                     port:4321
                                               phpVersion:nil];
    check(scriptIsValidShell(noPhp), @"senza versione di PHP è shell valida");

    // ------------------------------------------------------------- mysql
    section(@"MySQL");
    printf("      raggiungibile: %s\n", [XPDatabase isReachable] ? "sì" : "no");
    if (![XPDatabase isReachable]) {
        printf("      (fermo: i controlli sul server sono saltati)\n");
    } else if ([XPDatabase needsPassword]) {
        // ⚠️ È il caso di questa macchina: root ha una password e non è nel
        // portachiavi. Non è un difetto del codice, è il motivo per cui il
        // wizard la chiede quando si spunta la casella.
        printf("      root ha una password non salvata: il wizard la chiederà\n");
        check([XPDatabase passwordWorks:@"parola-sbagliata-per-forza"] == NO,
              @"una password sbagliata non fa entrare");
    } else {
        check(![XPDatabase databaseExists:@"nessun_database_con_questo_nome"],
              @"un database che non c'è risulta assente");
        check([XPDatabase databaseExists:@"mysql"], @"il database mysql risulta presente");
    }

    printf("\n\033[1m%d passati, %d falliti\033[0m\n\n", sPassed, sFailed);
    return sFailed == 0 ? 0 : 1;
}}
