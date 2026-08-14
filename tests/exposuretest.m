//
//  exposuretest.m
//  La riscrittura delle direttive Listen, provata sui file veri senza
//  toccarli: si legge la configurazione di questa macchina, la si riscrive in
//  memoria e si guarda cosa ne esce.
//
//  ⚠️ Una Listen sbagliata non lascia giù un progetto, li lascia giù tutti, e
//  Apache non riparte. Per questo la riscrittura si prova prima di collegarla
//  a un pulsante.
//

#import <Cocoa/Cocoa.h>
#import "XPExposure.h"
#import "XPNetwork.h"
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

/// Una configurazione finta, con dentro tutti i casi che il file vero ha.
static NSString *sample(void) {
    return
    @"# Listen: Allows you to bind Apache to specific IP addresses\n"
    @"#\n"
    @"#Listen 12.34.56.78:80\n"      // l'esempio della documentazione
    @"Listen 80\n"
    @"Listen 4000\n"
    @"# Listen 4003   # disabilitato: servita da php artisan serve\n"
    @"Listen 4004 https\n"           // con il protocollo in coda
    @"\n"
    @"ServerName virtualhost\n";
}

int main(void) { @autoreleasepool {
    printf("\n\033[1mChi raggiunge i progetti\033[0m\n");

    // ------------------------------------------------------------ indirizzo
    section(@"Indirizzo del Mac");
    NSString *address = [XPNetwork localAddress];
    if (address) {
        printf("      %s su %s\n", address.UTF8String,
               [XPNetwork localInterface].UTF8String);
        check(![address hasPrefix:@"127."], @"non è il loopback");
        check(![address hasPrefix:@"169.254."], @"non è un indirizzo senza DHCP");
        check([address componentsSeparatedByString:@"."].count == 4, @"è un IPv4");
        // ⚠️ Il fraintendimento da cui nasce tutto: l'indirizzo del router
        // finisce per .1, quello del Mac quasi mai.
        check([XPNetwork addressIsPrivate:address], @"è un indirizzo di rete privata");
    } else {
        printf("      (nessun indirizzo: il Mac non è in rete, controlli saltati)\n");
    }
    check(![XPNetwork addressIsPrivate:@"8.8.8.8"], @"8.8.8.8 non è privato");
    check([XPNetwork addressIsPrivate:@"10.0.0.4"], @"10.0.0.4 è privato");
    check([XPNetwork addressIsPrivate:@"172.20.1.1"], @"172.20.1.1 è privato");
    check(![XPNetwork addressIsPrivate:@"172.32.1.1"], @"172.32.1.1 NON è privato");

    // ------------------------------------------------------------ chiusura
    section(@"Riscrittura verso «solo questo Mac»");
    NSString *closed = [XPExposure rewrite:sample() toScope:XPExposureScopeThisMac];
    check(closed != nil, @"qualcosa da cambiare c'era");
    check([closed containsString:@"Listen 127.0.0.1:80\n"], @"la 80 è chiusa");
    check([closed containsString:@"Listen 127.0.0.1:4000\n"], @"la 4000 è chiusa");
    check([closed containsString:@"Listen 127.0.0.1:4004 https\n"],
          @"il protocollo in coda resta dov'è");

    // ⚠️ Il caso che romperebbe la documentazione di Apache, ed è la stessa
    // trappola del ServerAlias aggiunto con una regex.
    check([closed containsString:@"#Listen 12.34.56.78:80\n"],
          @"l'esempio commentato non viene toccato");
    check([closed containsString:@"# Listen 4003   # disabilitato"],
          @"la porta disabilitata resta commentata com'era");
    check([closed containsString:@"ServerName virtualhost\n"],
          @"il resto del file è intatto");

    // ------------------------------------------------------------ apertura
    section(@"Riscrittura verso «anche la rete locale»");
    NSString *reopened = [XPExposure rewrite:closed toScope:XPExposureScopeLocalNetwork];
    check(reopened != nil, @"si torna indietro");
    check([reopened isEqualToString:sample()], @"si torna esattamente al file di partenza");

    section(@"Chiamate che non devono fare niente");
    check([XPExposure rewrite:closed toScope:XPExposureScopeThisMac] == nil,
          @"riscrivere due volte non cambia niente");
    check([XPExposure rewrite:sample() toScope:XPExposureScopeInternet] == nil,
          @"Gateway non è ancora selezionabile");
    check([XPExposure rewrite:@"" toScope:XPExposureScopeThisMac] == nil,
          @"un file vuoto non produce modifiche");

    // ------------------------------------------------------ file veri
    section(@"La configurazione di questa macchina");
    printf("      radice: %s\n", [XPPaths installRoot].UTF8String);
    for (NSString *path in [XPExposure configurationFiles]) {
        BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:path];
        printf("      %s %s\n", exists ? "c'è " : "manca", path.lastPathComponent.UTF8String);
    }

    NSArray<NSNumber *> *ports = [XPExposure listenedPorts];
    printf("      porte dichiarate:");
    for (NSNumber *port in ports) printf(" %ld", (long)port.integerValue);
    printf("\n");
    check(ports.count > 0, @"almeno una porta è dichiarata");

    XPExposureScope scope = [XPExposure currentScope];
    printf("      adesso: %s\n", [XPExposure nameForScope:scope].UTF8String);
    check(scope != XPExposureScopeInternet, @"non è già su Gateway");

    // La prova che conta: riscrivere il file vero, in memoria, e ritrovarcelo
    // uguale tornando indietro. Se questa passa, il pulsante è sicuro.
    for (NSString *path in [XPExposure configurationFiles]) {
        NSString *text = [NSString stringWithContentsOfFile:path
                                                   encoding:NSUTF8StringEncoding
                                                      error:NULL];
        if (!text) continue;

        NSString *toClosed = [XPExposure rewrite:text toScope:XPExposureScopeThisMac];
        NSString *label = path.lastPathComponent;
        if (!toClosed) {
            printf("      %s: già chiuso, niente da provare\n", label.UTF8String);
            continue;
        }
        NSString *back = [XPExposure rewrite:toClosed toScope:XPExposureScopeLocalNetwork];
        check(back != nil && [back isEqualToString:text],
              [NSString stringWithFormat:@"%@ torna identico byte per byte", label]);

        NSUInteger before = [text componentsSeparatedByString:@"\n"].count;
        NSUInteger after = [toClosed componentsSeparatedByString:@"\n"].count;
        check(before == after,
              [NSString stringWithFormat:@"%@ non guadagna né perde righe", label]);
    }

    printf("\n\033[1m%d passati, %d falliti\033[0m\n\n", sPassed, sFailed);
    return sFailed == 0 ? 0 : 1;
}}
