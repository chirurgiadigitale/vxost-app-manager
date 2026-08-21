//
//  vhosttest.m
//  Quali blocchi di httpd-vhosts.conf sono progetti, e quali no.
//
//  ⚠️ Esiste per un difetto trovato il 21/08/2026: l'app mostrava
//  dummy-host.example.com fra i progetti. Sono i due blocchi che Apache scrive
//  di fabbrica nel suo httpd-vhosts.conf, non commentati, con un DocumentRoot
//  che punta a cartelle sotto docs/ che nello stack non esistono.
//
//  Chi ci cliccava finiva su http://dummy-host.example.com, un dominio che non
//  e' suo e che non risponde: sembra un difetto dell'app, ed e' la
//  configurazione che arriva cosi'. Colpisce soprattutto chi passa da XAMPP e
//  si porta dietro il file senza averlo mai aperto.
//
//  Il test legge il file originale vero, quello in etc/original/, quando c'e':
//  una copia scritta a mano nel test proverebbe che il codice fa quello che il
//  test si aspetta, non che regge la configurazione che le persone hanno.
//

#import <Cocoa/Cocoa.h>
#import "XPVirtualHost.h"
#import "XPPaths.h"

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

/// Scrive un file temporaneo e restituisce il percorso.
static NSString *writeTemp(NSString *contents, NSString *name) {
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:name];
    [contents writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    return path;
}

int main(void) { @autoreleasepool {
    printf("\n\033[1mI blocchi che non sono progetti\033[0m\n");

    // ---------------------------------------------------------------------
    section(@"La configurazione di fabbrica di Apache");

    NSString *stock =
    @"<VirtualHost *:80>\n"
    @"    ServerAdmin webmaster@dummy-host.example.com\n"
    @"    DocumentRoot \"/Applications/VXOST/vxostfiles/docs/dummy-host.example.com\"\n"
    @"    ServerName dummy-host.example.com\n"
    @"    ServerAlias www.dummy-host.example.com\n"
    @"</VirtualHost>\n"
    @"\n"
    @"<VirtualHost *:80>\n"
    @"    ServerAdmin webmaster@dummy-host2.example.com\n"
    @"    DocumentRoot \"/Applications/VXOST/vxostfiles/docs/dummy-host2.example.com\"\n"
    @"    ServerName dummy-host2.example.com\n"
    @"</VirtualHost>\n";

    NSString *path = writeTemp(stock, @"vxost-vhosttest-stock.conf");
    NSArray<XPVirtualHost *> *hosts = [XPVirtualHost hostsFromFile:path probePorts:NO];
    check(hosts.count == 0, @"i due blocchi di esempio non compaiono fra i progetti");

    // ---------------------------------------------------------------------
    section(@"Un progetto vero accanto agli esempi");

    NSString *misto = [stock stringByAppendingString:
    @"\n<VirtualHost *:4000>\n"
    @"    DocumentRoot \"/Applications/VXOST/vxostfiles/www/projects/mio-sito\"\n"
    @"    ServerName virtualhost\n"
    @"</VirtualHost>\n"];

    path = writeTemp(misto, @"vxost-vhosttest-misto.conf");
    hosts = [XPVirtualHost hostsFromFile:path probePorts:NO];
    check(hosts.count == 1, @"resta solo il progetto vero");
    check(hosts.firstObject.port == 4000, @"con la sua porta");
    check([hosts.firstObject.name isEqualToString:@"mio-sito"], @"e il suo nome");

    // ---------------------------------------------------------------------
    section(@"Non si butta via troppo");

    NSString *insidioso =
    @"<VirtualHost *:4001>\n"
    @"    DocumentRoot \"/Applications/VXOST/vxostfiles/www/projects/esempio\"\n"
    @"    ServerName virtualhost\n"
    @"</VirtualHost>\n"
    @"<VirtualHost *:4002>\n"
    @"    DocumentRoot \"/Applications/VXOST/vxostfiles/www/projects/docs-cliente\"\n"
    @"    ServerName virtualhost\n"
    @"</VirtualHost>\n"
    @"<VirtualHost *:4003>\n"
    @"    DocumentRoot \"/Applications/VXOST/vxostfiles/www/projects/example-app\"\n"
    @"    ServerName examples.local\n"
    @"</VirtualHost>\n";

    path = writeTemp(insidioso, @"vxost-vhosttest-insidioso.conf");
    hosts = [XPVirtualHost hostsFromFile:path probePorts:NO];
    check(hosts.count == 3,
          @"un progetto che si chiama esempio, uno con docs nel nome e uno "
          @"con example nel percorso restano tutti");

    // ---------------------------------------------------------------------
    section(@"Il file originale di questa installazione");

    NSString *originale = [XPPaths root:@"etc/original/extra/httpd-vhosts.conf"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:originale]) {
        NSArray<XPVirtualHost *> *daOriginale =
            [XPVirtualHost hostsFromFile:originale probePorts:NO];
        check(daOriginale.count == 0,
              @"il file di fabbrica non produce nemmeno un progetto");
    } else {
        check(YES, @"nessun etc/original su questa macchina, niente da provare");
    }

    // ---------------------------------------------------------------------
    section(@"Il file vero, quello in uso");

    NSArray<XPVirtualHost *> *veri = [XPVirtualHost allHosts];
    BOOL nessunEsempio = YES;
    for (XPVirtualHost *host in veri) {
        if ([[host.serverName lowercaseString] hasSuffix:@"example.com"]) nessunEsempio = NO;
        if ([host.documentRoot containsString:@"/docs/dummy-host"]) nessunEsempio = NO;
    }
    check(nessunEsempio, @"fra i progetti di questa macchina non c'e' un esempio");

    printf("\n\033[1m%d passati, %d falliti\033[0m\n\n", sPassed, sFailed);
    return sFailed == 0 ? 0 : 1;
}}
