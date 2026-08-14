//
//  XPDatabase.m
//

#import "XPDatabase.h"
#import "XPPaths.h"
#import "XPTaskRunner.h"

/// Il conto usato per amministrare. Sempre root: è l'unico che sicuramente
/// può creare database e utenti su un'installazione appena fatta.
static NSString *const XPAdminUser = @"root";

/// Voce del portachiavi. Un identificatore che dice cos'è, perché chi apre
/// Accesso Portachiavi deve capire cosa sta guardando.
static NSString *const XPKeychainService = @"VXOST MySQL root";

@implementation XPDatabase

#pragma mark - Portachiavi

+ (NSString *)storedPassword {
    NSDictionary *query = @{
        (id)kSecClass:            (id)kSecClassGenericPassword,
        (id)kSecAttrService:      XPKeychainService,
        (id)kSecAttrAccount:      XPAdminUser,
        (id)kSecReturnData:       @YES,
        (id)kSecMatchLimit:       (id)kSecMatchLimitOne,
    };
    CFTypeRef result = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &result) != errSecSuccess) {
        return nil;
    }
    NSData *data = CFBridgingRelease(result);
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

+ (void)storePassword:(NSString *)password {
    NSDictionary *identity = @{
        (id)kSecClass:       (id)kSecClassGenericPassword,
        (id)kSecAttrService: XPKeychainService,
        (id)kSecAttrAccount: XPAdminUser,
    };
    // Si cancella e si riscrive invece di aggiornare: l'aggiornamento fallisce
    // se la voce non c'è, e distinguere i due casi non aggiunge niente.
    SecItemDelete((__bridge CFDictionaryRef)identity);
    if (password.length == 0) return;

    NSMutableDictionary *item = [identity mutableCopy];
    item[(id)kSecValueData] = [password dataUsingEncoding:NSUTF8StringEncoding];
    item[(id)kSecAttrLabel] = @"VXOST";
    SecItemAdd((__bridge CFDictionaryRef)item, NULL);
}

#pragma mark - Connessione

/// Esegue una istruzione SQL con il client dello stack.
///
/// ⚠️ La password si passa in un file di configurazione temporaneo, mai con
/// --password sulla riga di comando: la riga di comando di un processo si
/// legge con `ps` da qualsiasi utente della macchina.
+ (XPTaskResult *)runSQL:(NSString *)sql password:(NSString *)password {
    NSString *client = [XPPaths root:@"bin/mysql"];
    NSString *socket = [XPPaths root:@"var/mysql/mysql.sock"];

    NSString *defaults = nil;
    if (password.length > 0) {
        defaults = [NSTemporaryDirectory() stringByAppendingPathComponent:
                    [NSString stringWithFormat:@"vxost-my-%@.cnf", [NSUUID UUID].UUIDString]];
        NSString *contents = [NSString stringWithFormat:
                              @"[client]\npassword=%@\n", password];
        [contents writeToFile:defaults atomically:YES
                     encoding:NSUTF8StringEncoding error:NULL];
        [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @(0600)}
                                         ofItemAtPath:defaults error:NULL];
    }

    NSMutableArray *arguments = [NSMutableArray array];
    if (defaults) [arguments addObject:[@"--defaults-extra-file=" stringByAppendingString:defaults]];
    [arguments addObjectsFromArray:@[
        [@"--socket=" stringByAppendingString:socket],
        [@"--user=" stringByAppendingString:XPAdminUser],
        @"--batch", @"--skip-column-names",
        @"--execute", sql,
    ]];

    XPTaskResult *result = [XPTaskRunner run:client arguments:arguments];
    if (defaults) [[NSFileManager defaultManager] removeItemAtPath:defaults error:NULL];
    return result;
}

+ (BOOL)isReachable {
    // ⚠️ "Raggiungibile" e "ci si entra" sono due cose diverse, e confonderle
    // porta a dire "MySQL non risponde" a chi ha solo una password impostata.
    // Qui si chiede solo se il server c'e': il socket esiste ed e' un socket.
    // L'autenticazione la valuta needsPassword.
    NSString *socket = [XPPaths root:@"var/mysql/mysql.sock"];
    NSDictionary *attributes = [[NSFileManager defaultManager]
                                attributesOfItemAtPath:socket error:NULL];
    return [attributes[NSFileType] isEqualToString:NSFileTypeSocket];
}

+ (BOOL)needsPassword {
    if ([self runSQL:@"SELECT 1" password:nil].succeeded) return NO;
    NSString *stored = [self storedPassword];
    if (stored && [self runSQL:@"SELECT 1" password:stored].succeeded) return NO;
    return YES;
}

+ (BOOL)passwordWorks:(NSString *)password {
    return [self runSQL:@"SELECT 1" password:password].succeeded;
}

/// La password che funziona: nessuna, o quella salvata.
+ (NSString *)workingPassword {
    if ([self runSQL:@"SELECT 1" password:nil].succeeded) return nil;
    return [self storedPassword];
}

#pragma mark - Password di root

+ (NSString *)setRootPassword:(NSString *)password {
    if (password.length == 0) return NSLocalizedString(@"db.err.empty", nil);

    NSString *current = [self workingPassword];
    if (![self runSQL:@"SELECT 1" password:current].succeeded) {
        return NSLocalizedString(@"db.password.wrong", nil);
    }

    // ⚠️ root non è un conto solo. MariaDB ne tiene uno per host: localhost,
    // 127.0.0.1, ::1 e spesso il nome della macchina. Cambiarne uno e basta
    // lascia gli altri con la password vecchia, e il risultato è un database
    // che accetta la password nuova da un indirizzo e la vecchia da un altro.
    XPTaskResult *hosts = [self runSQL:
        @"SELECT Host FROM mysql.user WHERE User = 'root'" password:current];
    NSMutableArray<NSString *> *targets = [NSMutableArray array];
    if (hosts.succeeded) {
        for (NSString *line in [hosts.output componentsSeparatedByString:@"\n"]) {
            NSString *host = [line stringByTrimmingCharactersInSet:
                              [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            // Il nome dell'host entra fra apici in una istruzione che gira come
            // root: si accettano solo i caratteri che un nome di host ha.
            NSRegularExpression *safe = [NSRegularExpression regularExpressionWithPattern:
                                         @"^[A-Za-z0-9._:%-]+$" options:0 error:NULL];
            if (host.length == 0) continue;
            if ([safe numberOfMatchesInString:host options:0
                                        range:NSMakeRange(0, host.length)] == 0) continue;
            [targets addObject:host];
        }
    }
    if (targets.count == 0) targets = [@[@"localhost", @"127.0.0.1"] mutableCopy];

    NSString *escaped = [[password stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"]
                         stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];

    NSMutableString *sql = [NSMutableString string];
    for (NSString *host in targets) {
        // SET PASSWORD e non ALTER USER: su MariaDB 10.4 funzionano
        // entrambi, ma SET PASSWORD funziona anche sulle versioni prima della
        // 10.2, e questo stack ne ha viste diverse.
        [sql appendFormat:@"SET PASSWORD FOR 'root'@'%@' = PASSWORD('%@'); ", host, escaped];
    }
    [sql appendString:@"FLUSH PRIVILEGES;"];

    XPTaskResult *result = [self runSQL:sql password:current];
    if (!result.succeeded) {
        NSString *message = [result.output stringByTrimmingCharactersInSet:
                             [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        return message.length > 0 ? message : NSLocalizedString(@"db.err.failed", nil);
    }

    // Si salva solo dopo aver verificato che la nuova password entra davvero.
    // Salvarla prima vorrebbe dire, in caso di errore a metà, un portachiavi
    // che dice una cosa e un server che ne dice un'altra.
    if (![self passwordWorks:password]) {
        return NSLocalizedString(@"db.password.wrong", nil);
    }
    [self storePassword:password];
    return nil;
}

#pragma mark - Nomi

+ (NSString *)validationErrorForDatabaseName:(NSString *)name {
    NSString *trimmed = [name stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) {
        return NSLocalizedString(@"db.err.empty", nil);
    }
    // MySQL arriva a 64, ma il nome finisce anche in un utente, che si ferma
    // a 32 nelle versioni prima della 8: il limite più basso vale per entrambi.
    if (trimmed.length > 32) {
        return NSLocalizedString(@"db.err.tooLong", nil);
    }
    // ⚠️ Insieme di caratteri ristretto apposta. Il nome entra in una
    // istruzione SQL che gira come root, e i nomi di database non si possono
    // passare come parametri preparati: si possono solo controllare prima.
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:
                               @"^[a-z][a-z0-9_]*$" options:0 error:NULL];
    if ([re numberOfMatchesInString:trimmed options:0
                              range:NSMakeRange(0, trimmed.length)] == 0) {
        return NSLocalizedString(@"db.err.format", nil);
    }
    return nil;
}

+ (BOOL)databaseExists:(NSString *)name {
    if ([self validationErrorForDatabaseName:name] != nil) return NO;
    NSString *sql = [NSString stringWithFormat:
        @"SELECT SCHEMA_NAME FROM information_schema.SCHEMATA "
        @"WHERE SCHEMA_NAME = '%@'", name];
    XPTaskResult *result = [self runSQL:sql password:[self workingPassword]];
    return result.succeeded &&
           [result.output stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]].length > 0;
}

#pragma mark - Creazione

+ (NSString *)createDatabase:(NSString *)database
                        user:(NSString *)user
                    password:(NSString *)password {

    NSString *problem = [self validationErrorForDatabaseName:database];
    if (problem) return problem;

    // Utente vuoto vuol dire "solo il database".
    //
    // In locale ci si collega come root, e un utente dedicato sarebbe una
    // credenziale in più da comunicare a chi crea il progetto e da ritrovare
    // il giorno dopo. Resta possibile crearlo passando un nome.
    if (user.length == 0) {
        NSString *createOnly = [NSString stringWithFormat:
            @"CREATE DATABASE IF NOT EXISTS `%@` "
            @"CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;", database];
        XPTaskResult *onlyResult = [self runSQL:createOnly password:[self workingPassword]];
        if (onlyResult.succeeded) return nil;
        NSString *why = [onlyResult.output stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        return why.length > 0 ? why : NSLocalizedString(@"db.err.failed", nil);
    }

    problem = [self validationErrorForDatabaseName:user];
    if (problem) return problem;

    // La password dell'utente nuovo entra fra apici in una istruzione: gli
    // apici e le barre si raddoppiano, o una password con un apice spezza
    // l'istruzione. Non è un caso di attacco, è un caso di password normale.
    NSString *escaped = [[(password ?: @"") stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"]
                         stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];

    NSString *sql = [NSString stringWithFormat:
        @"CREATE DATABASE IF NOT EXISTS `%1$@` "
        @"CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; "
        @"CREATE USER IF NOT EXISTS '%2$@'@'localhost' IDENTIFIED BY '%3$@'; "
        @"CREATE USER IF NOT EXISTS '%2$@'@'127.0.0.1' IDENTIFIED BY '%3$@'; "
        @"GRANT ALL PRIVILEGES ON `%1$@`.* TO '%2$@'@'localhost'; "
        @"GRANT ALL PRIVILEGES ON `%1$@`.* TO '%2$@'@'127.0.0.1'; "
        @"FLUSH PRIVILEGES;",
        database, user, escaped];

    XPTaskResult *result = [self runSQL:sql password:[self workingPassword]];
    if (result.succeeded) return nil;

    // ⚠️ L'errore di MySQL arriva com'è, non tradotto in "operazione fallita":
    // "Access denied" e "Unknown collation" si risolvono in modi diversi, e
    // nasconderli dietro un messaggio generico costa mezz'ora a chi legge.
    NSString *message = [result.output stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return message.length > 0 ? message : NSLocalizedString(@"db.err.failed", nil);
}

@end
