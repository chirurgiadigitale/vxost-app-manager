#import <Cocoa/Cocoa.h>
#import "XPVirtualHost.h"
#import "XPPhpVersion.h"

static int P=0,F=0;
static void check(BOOL c, NSString *w){ if(c){P++;printf("  \033[32m✓\033[0m %s\n",w.UTF8String);}
    else {F++;printf("  \033[31m✗ %s\033[0m\n",w.UTF8String);} }
static void section(NSString *t){ printf("\n\033[1m%s\033[0m\n",t.UTF8String); }

static NSString *plain(void) {
    return
    @"# VXOST wizard: demo\n"
    @"<VirtualHost *:4000>\n"
    @"    DocumentRoot \"/x/demo\"\n"
    @"    ServerName virtualhost\n"
    @"    ErrorLog \"logs/demo-error_log\"\n"
    @"</VirtualHost>\n"
    @"\n"
    @"<VirtualHost *:4001>\n"
    @"    DocumentRoot \"/x/other\"\n"
    @"</VirtualHost>\n";
}

static NSString *directive(void) {
    return
    @"    # PHP 8.5.5 through its own php-fpm pool. Without this block the\n"
    @"    # project uses the version compiled into the stack.\n"
    @"    <FilesMatch \"\\.php$\">\n"
    @"        SetHandler \"proxy:unix:/tmp/vxost-php85.sock|fcgi://localhost\"\n"
    @"    </FilesMatch>\n";
}

int main(void){ @autoreleasepool {
    printf("\n\033[1mVersione di PHP per progetto\033[0m\n");

    section(@"Aggiunta");
    NSString *with = [XPVirtualHost configuration:plain() settingPhp:directive() forPort:4000];
    check(with != nil, @"qualcosa è cambiato");
    check([with containsString:@"proxy:unix:/tmp/vxost-php85.sock"], @"il blocco c'è");
    NSRange handler = [with rangeOfString:@"SetHandler"];
    NSRange firstClose = [with rangeOfString:@"</VirtualHost>"];
    check(handler.location < firstClose.location, @"sta dentro il primo blocco");
    check([with componentsSeparatedByString:@"proxy:unix:"].count == 2, @"una volta sola");
    check([with containsString:@"<VirtualHost *:4001>"], @"l'altro progetto c'è ancora");
    check(![[with substringFromIndex:firstClose.location] containsString:@"SetHandler"],
          @"l'altro progetto non è stato toccato");

    section(@"Sostituzione");
    NSString *other =
        @"    <FilesMatch \"\\.php$\">\n"
        @"        SetHandler \"proxy:unix:/tmp/vxost-php82.sock|fcgi://localhost\"\n"
        @"    </FilesMatch>\n";
    NSString *swapped = [XPVirtualHost configuration:with settingPhp:other forPort:4000];
    check(swapped != nil, @"cambiare versione cambia il file");
    check([swapped containsString:@"vxost-php82.sock"], @"c'è la versione nuova");
    check(![swapped containsString:@"vxost-php85.sock"], @"la vecchia è sparita");
    check([swapped componentsSeparatedByString:@"proxy:unix:"].count == 2, @"non si accumulano");
    check(![swapped containsString:@"# PHP 8.5.5 through"], @"i commenti della vecchia sono spariti");

    section(@"Ritorno alla versione dello stack");
    NSString *back = [XPVirtualHost configuration:with settingPhp:@"" forPort:4000];
    check(back != nil, @"togliere il blocco cambia il file");
    check(![back containsString:@"proxy:unix:"], @"il blocco è sparito");
    check([back isEqualToString:plain()], @"si torna esattamente al file di partenza");

    section(@"Cose che non devono succedere");
    check([XPVirtualHost configuration:plain() settingPhp:@"" forPort:4000] == nil,
          @"togliere un blocco che non c'è non cambia niente");
    check([XPVirtualHost configuration:plain() settingPhp:directive() forPort:9999] == nil,
          @"una porta che non esiste non cambia niente");

    // ⚠️ Il FilesMatch che non c'entra: cancellarlo sarebbe un disastro
    // silenzioso, perché è quello che protegge i file nascosti.
    NSString *guarded =
        @"<VirtualHost *:4000>\n"
        @"    DocumentRoot \"/x/demo\"\n"
        @"    <FilesMatch \"^\\.\">\n"
        @"        Require all denied\n"
        @"    </FilesMatch>\n"
        @"</VirtualHost>\n";
    NSString *guardedOut = [XPVirtualHost configuration:guarded settingPhp:directive() forPort:4000];
    check([guardedOut containsString:@"Require all denied"], @"un FilesMatch estraneo resta");
    check([guardedOut containsString:@"^\\."], @"con il suo pattern");

    // Blocco commentato: e' un progetto spento e non si tocca.
    NSString *disabled =
        @"# <VirtualHost *:4002>\n"
        @"#     DocumentRoot \"/x/off\"\n"
        @"# </VirtualHost>\n";
    check([XPVirtualHost configuration:disabled settingPhp:directive() forPort:4002] == nil,
          @"un progetto spento non viene toccato");

    section(@"Socket e versione si incrociano");
    NSArray<XPPhpVersion *> *all = [XPPhpVersion available];
    XPPhpVersion *external = nil;
    for (XPPhpVersion *v in all) if (!v.isBundled) { external = v; break; }
    check([XPPhpVersion versionForSocket:nil].isBundled, @"nessun socket = versione dello stack");
    if (external) {
        // ⚠️ Si confronta la versione, non il puntatore: +available interroga
        // i binari a ogni chiamata e restituisce oggetti nuovi. Confrontare gli
        // indirizzi qui faceva fallire un test su codice giusto.
        XPPhpVersion *found = [XPPhpVersion versionForSocket:external.socketPath];
        check([found.version isEqualToString:external.version],
              @"il socket ritrova la sua versione");
    }
    check([XPPhpVersion versionForSocket:@"/tmp/vxost-php40.sock"] == nil,
          @"un socket di una versione non installata non diventa un'altra versione");

    printf("\n\033[1m%d passati, %d falliti\033[0m\n\n",P,F);
    return F==0?0:1;
}}
