//
//  selettoritest.m
//  I tre selettori dei progetti con nomi duplicati e aggiornamenti in corso.
//
//  Costruito sulla prova del dodicesimo giro di Codex. Due difetti che
//  registravano ore su un progetto mai scelto:
//  - scelto "Nuovo progetto", un aggiornamento del tracker riportava la
//    selezione sulla prima voce, e "Avvia" apriva una sessione li';
//  - l'inserimento manuale dalla cronologia leggeva la POSIZIONE, e con due
//    progetti omonimi registrava sul progetto accanto.
//
//  L'elenco dei progetti e' sostituito (allProjects) e lo storico dirottato
//  in un file temporaneo: nessun dato vero viene letto o scritto.
//
#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#import "XPTracker.h"
#import "XPTimeEntry.h"
#import "XPTimerSectionView.h"
#import "XPHistoryWindowController.h"
#import "XPEntryEditor.h"

@interface XPTimerSectionView (Test)
- (void)startFromPicker; - (void)refresh; - (void)menuNeedsUpdate:(NSMenu *)menu; - (void)promptForCustomProject;
@end
@interface XPHistoryWindowController (Test)
- (void)rebuildReportPickers; - (NSString *)selectedProjectKey;
@end
@interface XPEntryEditor (Test)
- (void)presentOn:(NSWindow *)window title:(NSString *)title; - (void)save:(id)sender;
@end
@interface TestTimer : XPTimerSectionView
@property NSInteger prompts;
@end
@implementation TestTimer
- (void)promptForCustomProject { self.prompts++; }   // niente finestra modale
@end

static int sPassed = 0, sFailed = 0;
static void check(BOOL ok, NSString *what) {
    if (ok) { sPassed++; printf("  \033[32m✓\033[0m %s\n", what.UTF8String); }
    else    { sFailed++; printf("  \033[31m✗ %s\033[0m\n", what.UTF8String); }
}
static NSArray *sProjects;
static XPTrackableProject *proj(NSString *key, NSString *name) {
    XPTrackableProject *p = [XPTrackableProject new]; p.key = key; p.name = name; return p;
}

int main(void) { @autoreleasepool {
    NSString *store = [NSTemporaryDirectory() stringByAppendingPathComponent:
                       [NSString stringWithFormat:@"vxost-selettoritest-%d.json", getpid()]];
    setenv("VXOST_TRACKER_STORE", store.fileSystemRepresentation, 1);
    [NSApplication sharedApplication];
    sProjects = @[proj(@"test:alpha", @"Alpha"), proj(@"test:twin1", @"Twin"),
                  proj(@"test:twin2", @"Twin"), proj(@"test:omega", @"Omega")];
    Method m = class_getInstanceMethod([XPTracker class], @selector(allProjects));
    method_setImplementation(m, imp_implementationWithBlock(^id(id s) { return sProjects; }));
    XPTracker *tracker = [XPTracker shared];

    printf("\n\033[1mMenu accanto ad Avvia\033[0m\n");
    TestTimer *view = [TestTimer new];
    NSPopUpButton *p = [view valueForKey:@"projectPicker"];
    check(p.numberOfItems - 2 == 4, @"quattro progetti in menu anche con due nomi uguali");
    [p selectItemAtIndex:[p.menu indexOfItemWithRepresentedObject:@"test:twin2"]];
    [view menuNeedsUpdate:p.menu];
    [view startFromPicker];
    check([tracker.currentEntries.firstObject.projectKey isEqualToString:@"test:twin2"],
          @"scelto il secondo Twin, la sessione e' sul secondo Twin");
    [tracker stopAll];

    [p selectItemAtIndex:p.numberOfItems - 1];
    [[NSNotificationCenter defaultCenter] postNotificationName:XPTrackerDidChangeNotification object:tracker];
    NSUInteger prima = tracker.currentEntries.count;
    [view startFromPicker];
    check(view.prompts == 1, @"scelto Nuovo progetto, dopo un aggiornamento chiede ancora il nome");
    check(tracker.currentEntries.count == prima, @"e non avvia nessun progetto esistente");
    [tracker stopAll];

    printf("\n\033[1mFiltro della cronologia\033[0m\n");
    XPHistoryWindowController *h = [XPHistoryWindowController new];
    [h rebuildReportPickers];
    NSPopUpButton *hp = [h valueForKey:@"projectPicker"];
    check(hp.numberOfItems - 1 == 4, @"quattro progetti anche con due nomi uguali");
    [hp selectItemAtIndex:[hp.menu indexOfItemWithRepresentedObject:@"test:twin2"]];
    [h rebuildReportPickers];
    check([[h selectedProjectKey] isEqualToString:@"test:twin2"], @"la scelta sopravvive alla ricostruzione");

    printf("\n\033[1mInserimento manuale\033[0m\n");
    XPEntryEditor *editor = [XPEntryEditor new];
    [editor setValue:[NSDate date] forKey:@"day"];
    [editor presentOn:nil title:@"test"];
    NSPopUpButton *ep = [editor valueForKey:@"projectPopup"];
    check(ep.numberOfItems == 4, @"quattro progetti anche con due nomi uguali");
    [ep selectItemWithTitle:@"Omega"];
    [editor save:nil];
    XPTimeEntry *salvata = nil;
    for (XPTimeEntry *e in [tracker entriesForDay:[NSDate date]]) if (e.duration > 0) salvata = e;
    check([salvata.projectKey isEqualToString:@"test:omega"],
          [NSString stringWithFormat:@"scelto Omega, salvata su Omega (e' finita su %@)", salvata.projectKey ?: @"niente"]);

    [[NSFileManager defaultManager] removeItemAtPath:store error:NULL];
    printf("\n\033[1m%d passati, %d falliti\033[0m\n\n", sPassed, sFailed);
    return sFailed ? 1 : 0;
}}
