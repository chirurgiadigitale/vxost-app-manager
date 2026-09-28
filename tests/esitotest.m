//
//  esitotest.m
//  Come l'app legge l'esito dello script che scrive la configurazione.
//
//  Questo file esiste per un difetto trovato il 28/09/2026: VXOST_OK_UNVERIFIED
//  impostava ok = YES in due punti con la logica copiata, il wizard si
//  chiudeva come dopo un successo, e del messaggio arrivava solo la prima
//  riga, troncata sui due punti: "Open the site before relying on it" non lo
//  leggeva nessuno.
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

int main(void) { @autoreleasepool {
    // L'uscita vera del ramo "non verificato", come la stampa lo script.
    NSString *nonVerificato =
        @"NOTE: Apache is running, but the reload could not be verified:\n"
        @"the error log gives no proof tied to this attempt (unreadable log, or the\n"
        @"server process did not change).\n"
        @"Open the site before relying on it.\n"
        @"VXOST_OK_UNVERIFIED\n";

    section(@"Tre esiti, letti in un punto solo");
    check(XPScriptOutcomeOf(@"Syntax OK\nVXOST_OK\n") == XPScriptOutcomeVerified,
          @"VXOST_OK e' verificato");
    check(XPScriptOutcomeOf(nonVerificato) == XPScriptOutcomeUnverified,
          @"VXOST_OK_UNVERIFIED non e' verificato (containsString: trova OK anche li' dentro)");
    check(XPScriptOutcomeOf(@"VXOST_RESTART_FAILED\n") == XPScriptOutcomeFailed,
          @"un riavvio fallito e' fallito");
    check(XPScriptOutcomeOf(@"") == XPScriptOutcomeFailed,
          @"un'uscita vuota e' un fallimento, non un successo");

    section(@"Il messaggio del non verificato arriva intero");
    NSString *m = XPUnverifiedMessage(nonVerificato);
    check([m containsString:@"could not be verified"], @"dice che non e' verificato");
    check([m containsString:@"Open the site before relying on it"], @"dice cosa fare");
    check(![m containsString:@"VXOST_OK"], @"non mostra il marcatore");
    check(![m containsString:@"\n"], @"sta su una riga, senza a capo spezzati");
    NSString *senzaNota = XPUnverifiedMessage(@"VXOST_OK_UNVERIFIED\n");
    check([senzaNota containsString:@"could not be verified"],
          @"senza la riga NOTE: dice comunque 'non verificato', non 'fallito'");

    section(@"Lo script stampa davvero quel testo");
    NSString *script = [[XPActions shared] configurationScriptFor:@{@"/tmp/a": @"/tmp/b"}];
    check([script containsString:@"Open the site before relying on it."],
          @"la frase che il test si aspetta e' nello script generato");
    check([script containsString:@"echo VXOST_OK_UNVERIFIED"], @"e anche il marcatore");

    printf("\n\033[1m%d passati, %d falliti\033[0m\n\n", P, F);
    return F == 0 ? 0 : 1;
}}
