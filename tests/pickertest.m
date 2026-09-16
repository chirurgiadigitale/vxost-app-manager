//
//  pickertest.m
//  Il menu dei progetti accanto ad "Avvia", provato sulla vista vera.
//
//  ⚠️ Il difetto trovato da Davide il 16/09/2026: il menu si costruiva solo
//  quando cambiava il time tracking, quindi una cartella aggiunta o tolta dal
//  Finder non si vedeva; e "Avvia" prendeva il progetto per POSIZIONE da un
//  elenco riletto al clic, cosi' una cartella sparita nel frattempo faceva
//  finire le ore sul progetto accanto, senza nessun avviso.
//
//  Cartelle e storico sono dirottati in una directory temporanea PRIMA di
//  creare qualunque oggetto: la www/projects vera non viene toccata.
//

#import <Cocoa/Cocoa.h>
#include <stdlib.h>
#import "XPTracker.h"
#import "XPTimeEntry.h"
#import "XPTimerSectionView.h"

@interface XPTimerSectionView (PerIlTest)
- (void)startFromPicker;
- (void)menuNeedsUpdate:(NSMenu *)menu;
@end

static int sPassed = 0, sFailed = 0;
static void check(BOOL ok, NSString *what) {
    if (ok) { sPassed++; printf("  \033[32m✓\033[0m %s\n", what.UTF8String); }
    else    { sFailed++; printf("  \033[31m✗ %s\033[0m\n", what.UTF8String); }
}
static NSInteger indexOfTitle(NSPopUpButton *p, NSString *t) {
    for (NSInteger i = 0; i < p.numberOfItems; i++)
        if ([[p itemAtIndex:i].title isEqualToString:t]) return i;
    return -1;
}

int main(void) {
    @autoreleasepool {
        NSString *base = [NSTemporaryDirectory() stringByAppendingPathComponent:
                          [NSString stringWithFormat:@"vxost-pickertest-%d", getpid()]];
        NSString *root = [base stringByAppendingPathComponent:@"projects"];
        NSFileManager *fm = [NSFileManager defaultManager];
        for (NSString *n in @[@"zz-alfa", @"zz-beta", @"zz-gamma", @"zz-omega"]) {
            [fm createDirectoryAtPath:[root stringByAppendingPathComponent:n]
          withIntermediateDirectories:YES attributes:nil error:NULL];
        }
        setenv("VXOST_PROJECTS_ROOT", root.fileSystemRepresentation, 1);
        setenv("VXOST_TRACKER_STORE",
               [base stringByAppendingPathComponent:@"timesheet.json"].fileSystemRepresentation, 1);

        [NSApplication sharedApplication];
        XPTracker *tracker = [XPTracker shared];
        XPTimerSectionView *view = [[XPTimerSectionView alloc] init];
        NSPopUpButton *picker = [view valueForKey:@"projectPicker"];

        printf("\n\033[1mUna cartella aggiunta dal Finder compare aprendo il menu\033[0m\n");
        [fm createDirectoryAtPath:[root stringByAppendingPathComponent:@"zz-galizzi"]
      withIntermediateDirectories:YES attributes:nil error:NULL];
        check(indexOfTitle(picker, @"zz-galizzi") < 0, @"prima di aprire il menu non c'e' (premessa della prova)");
        if ([view respondsToSelector:@selector(menuNeedsUpdate:)]) [view menuNeedsUpdate:picker.menu];
        check(indexOfTitle(picker, @"zz-galizzi") >= 0, @"aperto il menu, la cartella nuova c'e'");

        printf("\n\033[1mUna cartella tolta dal Finder sparisce aprendo il menu\033[0m\n");
        [fm removeItemAtPath:[root stringByAppendingPathComponent:@"zz-alfa"] error:NULL];
        if ([view respondsToSelector:@selector(menuNeedsUpdate:)]) [view menuNeedsUpdate:picker.menu];
        check(indexOfTitle(picker, @"zz-alfa") < 0, @"aperto il menu, la cartella tolta non c'e' piu'");

        printf("\n\033[1mUna cartella sparisce DOPO aver scelto: le ore non vanno sul progetto accanto\033[0m\n");
        if ([view respondsToSelector:@selector(menuNeedsUpdate:)]) [view menuNeedsUpdate:picker.menu];
        NSInteger g = indexOfTitle(picker, @"zz-gamma");
        [picker selectItemAtIndex:g];
        // zz-beta sta prima di zz-gamma: togliendola, le posizioni scorrono di uno
        [fm removeItemAtPath:[root stringByAppendingPathComponent:@"zz-beta"] error:NULL];
        [view startFromPicker];
        XPTimeEntry *e = tracker.currentEntries.firstObject;
        check(tracker.currentEntries.count == 1, @"e' partita una sessione sola");
        check([e.projectKey isEqualToString:@"folder:zz-gamma"],
              [NSString stringWithFormat:@"registrata su zz-gamma (e' finita su %@)", e.projectKey ?: @"niente"]);
        [tracker stopAll];

        printf("\n\033[1mIl progetto scelto sparisce prima del clic: non si registra niente\033[0m\n");
        if ([view respondsToSelector:@selector(menuNeedsUpdate:)]) [view menuNeedsUpdate:picker.menu];
        [picker selectItemAtIndex:indexOfTitle(picker, @"zz-galizzi")];
        [fm removeItemAtPath:[root stringByAppendingPathComponent:@"zz-galizzi"] error:NULL];
        NSUInteger prima = tracker.currentEntries.count;
        [view startFromPicker];
        check(tracker.currentEntries.count == prima, @"nessuna sessione partita su un altro progetto");
        check(indexOfTitle(picker, @"zz-galizzi") < 0, @"e il menu si e' aggiornato");

        [tracker stopAll];

        printf("\n\033[1mProgetto sparito, poi un aggiornamento, poi Avvia: nessun ripiego\033[0m\n");
        [fm createDirectoryAtPath:[root stringByAppendingPathComponent:@"zz-delta"]
      withIntermediateDirectories:YES attributes:nil error:NULL];
        if ([view respondsToSelector:@selector(menuNeedsUpdate:)]) [view menuNeedsUpdate:picker.menu];
        [picker selectItemAtIndex:indexOfTitle(picker, @"zz-delta")];
        [fm removeItemAtPath:[root stringByAppendingPathComponent:@"zz-delta"] error:NULL];
        // la notifica che arriva, per esempio, mentre un timer scorre
        [[NSNotificationCenter defaultCenter] postNotificationName:XPTrackerDidChangeNotification object:tracker];
        [[NSNotificationCenter defaultCenter] postNotificationName:XPTrackerDidChangeNotification object:tracker];
        prima = tracker.currentEntries.count;
        [view startFromPicker];
        check(tracker.currentEntries.count == prima,
              [NSString stringWithFormat:@"nessuna sessione avviata al posto di zz-delta (avviata: %@)",
               tracker.currentEntries.lastObject.projectKey ?: @"niente"]);
        [tracker stopAll];
        [fm removeItemAtPath:base error:NULL];
        check(![fm fileExistsAtPath:base], @"il test non lascia niente dietro di se'");
    }
    printf("\n\033[1m%d passati, %d falliti\033[0m\n\n", sPassed, sFailed);
    return sFailed ? 1 : 0;
}
