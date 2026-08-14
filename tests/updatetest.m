//
//  updatetest.m
//  Il confronto fra numeri di versione, che è il punto in cui questa funzione
//  può sbagliare in silenzio: se sbaglia, o non annuncia un aggiornamento che
//  c'è, o ne annuncia uno che non c'è.
//
//  ⚠️ L'ultima parte tocca la rete e chiede a vxost.com il file delle
//  versioni. Se il file non è ancora pubblicato o non c'è connessione lo dice
//  e va avanti: non è un test che deve fallire su un treno.
//

#import <Foundation/Foundation.h>
#import "XPUpdateCheck.h"

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

static BOOL newer(NSString *a, NSString *b) {
    return [XPUpdateCheck compareVersion:a with:b] == NSOrderedDescending;
}

static BOOL same(NSString *a, NSString *b) {
    return [XPUpdateCheck compareVersion:a with:b] == NSOrderedSame;
}

int main(void) { @autoreleasepool {
    printf("\n\033[1mControllo aggiornamenti\033[0m\n");

    section(@"Confronto fra versioni");
    check(newer(@"9.27.0", @"9.26.0"), @"9.27.0 è più recente di 9.26.0");
    check(newer(@"10.0.0", @"9.99.99"), @"10.0.0 è più recente di 9.99.99");
    check(newer(@"9.26.1", @"9.26.0"), @"9.26.1 è più recente di 9.26.0");

    // ⚠️ Il caso per cui questo metodo esiste. Confrontando le stringhe,
    // "9.9.0" verrebbe dopo "9.26.0" perché '9' viene dopo '2'.
    check(!newer(@"9.9.0", @"9.26.0"), @"9.9.0 NON è più recente di 9.26.0");
    check(newer(@"9.26.0", @"9.9.0"), @"9.26.0 è più recente di 9.9.0");

    check(same(@"9.26.0", @"9.26.0"), @"la stessa versione è la stessa");
    check(same(@"9.26", @"9.26.0"), @"9.26 e 9.26.0 sono la stessa versione");
    check(same(@"9", @"9.0.0"), @"9 e 9.0.0 sono la stessa versione");
    check(!newer(@"9.26.0", @"9.27.0"), @"non si torna indietro");

    // Roba malformata: deve dare una risposta, non far cadere l'app.
    check(!newer(@"", @"9.26.0"), @"una versione vuota non è più recente");
    check(!newer(nil, @"9.26.0"), @"nil non è più recente");
    check(!newer(@"pippo", @"9.26.0"), @"testo qualsiasi non è più recente");
    check(newer(@"9.26.0", @"pippo"), @"9.26.0 batte il testo qualsiasi");
    check(!newer(@"9.26.0-beta", @"9.26.0"), @"9.26.0-beta non supera 9.26.0");

    section(@"Preferenza");
    XPUpdateCheck *updates = [XPUpdateCheck shared];
    BOOL wasAutomatic = updates.automatic;

    // ⚠️ Il caso che il codice ovvio sbaglia: senza la chiave salvata,
    // boolForKey: risponde no, e il controllo automatico nascerebbe spento
    // pur essendo acceso per scelta.
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"UpdateCheckEnabled"];
    check(updates.automatic, @"senza preferenza salvata è acceso");

    updates.automatic = NO;
    check(!updates.automatic, @"si può spegnere");
    check(updates.availableVersion == nil, @"spegnendolo si dimentica cosa si sapeva");

    updates.automatic = YES;
    check(updates.automatic, @"si può riaccendere");
    updates.automatic = wasAutomatic;   // com'era prima del test

    section(@"Il file sul sito");
    NSURL *url = [NSURL URLWithString:@"https://vxost.com/version.json"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                                                          cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                      timeoutInterval:10];
    // Una richiesta sincrona in un programma da riga di comando: il semaforo
    // fa aspettare, perché senza un run loop la callback non arriverebbe mai
    // e il test finirebbe prima della risposta.
    __block NSData *data = nil;
    __block NSInteger status = 0;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [[[NSURLSession sharedSession] dataTaskWithRequest:request
        completionHandler:^(NSData *body, NSURLResponse *response, NSError *error) {
            (void)error;
            data = body;
            status = [(NSHTTPURLResponse *)response statusCode];
            dispatch_semaphore_signal(done);
        }] resume];
    dispatch_semaphore_wait(done,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_SEC)));
    if (!data || status != 200) {
        printf("      non raggiungibile (codice %ld): il controllo dal vivo è saltato\n",
               (long)status);
        printf("      ⚠️ finché vxost.com/version.json non esiste, l'app non\n");
        printf("         annuncerà mai un aggiornamento\n");
    } else {
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        check([json isKindOfClass:[NSDictionary class]], @"il file è un oggetto JSON");
        check([json[@"version"] isKindOfClass:[NSString class]],
              @"version è una stringa, non un numero");
        check([json[@"url"] isKindOfClass:[NSString class]], @"url è una stringa");
        printf("      versione pubblicata: %s\n",
               [json[@"version"] description].UTF8String);
    }

    printf("\n\033[1m%d passati, %d falliti\033[0m\n\n", sPassed, sFailed);
    return sFailed == 0 ? 0 : 1;
}}
