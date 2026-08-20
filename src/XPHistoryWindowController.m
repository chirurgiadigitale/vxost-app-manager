//
//  XPHistoryWindowController.m
//

#import "XPHistoryWindowController.h"
#import "XPTheme.h"
#import "XPTracker.h"
#import "XPTimeEntry.h"
#import "XPTimerSectionView.h"
#import "XPReport.h"
#import "XPButton.h"
#import "XPEntryEditor.h"
#import "XPGitLog.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface XPHistoryWindowController () <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, strong) NSTableView *daysTable;
@property (nonatomic, strong) NSArray<NSDate *> *days;
/// Il giorno attualmente mostrato a destra.
@property (nonatomic, strong) NSDate *selectedDay;
@property (nonatomic, strong) NSStackView *entriesStack;
@property (nonatomic, strong) NSStackView *projectTotalsStack;
@property (nonatomic, strong) NSTextField *dayTitle;
@property (nonatomic, strong) NSTextField *dayTotal;
@property (nonatomic, strong) NSTextField *emptyLabel;
@property (nonatomic, strong) NSDateFormatter *dayFormatter;
@property (nonatomic, strong) NSDateFormatter *timeFormatter;

// Riepilogo da mandare al cliente
@property (nonatomic, strong) NSPopUpButton *periodPicker;
@property (nonatomic, strong) NSPopUpButton *projectPicker;
@property (nonatomic, strong) NSTextField *reportTotalLabel;
@property (nonatomic, strong) XPButton *clipboardButton;
@property (nonatomic, strong) XPButton *csvButton;
/// Aggiunge a mano una sessione al giorno mostrato.
@property (nonatomic, strong) XPButton *addButton;
@property (nonatomic, strong) NSArray<NSString *> *reportProjectKeys;
@end


@implementation XPHistoryWindowController

+ (instancetype)shared {
    static XPHistoryWindowController *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[XPHistoryWindowController alloc] init]; });
    return shared;
}

- (instancetype)init {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 780, 520)
                                                   styleMask:(NSWindowStyleMaskTitled |
                                                              NSWindowStyleMaskClosable |
                                                              NSWindowStyleMaskMiniaturizable |
                                                              NSWindowStyleMaskResizable)
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    window.releasedWhenClosed = NO;
    window.backgroundColor = [XPTheme bg];
    window.collectionBehavior |= NSWindowCollectionBehaviorFullScreenPrimary;
    window.minSize = NSMakeSize(620, 420);
    [window center];

    if ((self = [super initWithWindow:window])) {
        _dayFormatter = [[NSDateFormatter alloc] init];
        _dayFormatter.dateStyle = NSDateFormatterFullStyle;
        _dayFormatter.timeStyle = NSDateFormatterNoStyle;
        _dayFormatter.doesRelativeDateFormatting = YES;   // "Oggi", "Ieri"

        _timeFormatter = [[NSDateFormatter alloc] init];
        _timeFormatter.dateStyle = NSDateFormatterNoStyle;
        _timeFormatter.timeStyle = NSDateFormatterShortStyle;

        [self buildInterface];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(trackerDidChange:)
                                                     name:XPTrackerDidChangeNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(themeDidChange:)
                                                     name:XPThemeDidChangeNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Costruzione

- (void)buildInterface {
    self.window.title = NSLocalizedString(@"history.title", nil);

    NSView *content = self.window.contentView;
    content.wantsLayer = YES;

    // --- Elenco dei giorni, a sinistra ---
    NSScrollView *daysScroll = [[NSScrollView alloc] init];
    daysScroll.translatesAutoresizingMaskIntoConstraints = NO;
    daysScroll.hasVerticalScroller = YES;
    daysScroll.borderType = NSNoBorder;
    daysScroll.drawsBackground = NO;

    self.daysTable = [[NSTableView alloc] init];
    self.daysTable.headerView = nil;
    self.daysTable.rowHeight = 44;
    self.daysTable.backgroundColor = [NSColor clearColor];
    self.daysTable.style = NSTableViewStyleInset;
    self.daysTable.dataSource = self;
    self.daysTable.delegate = self;

    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"day"];
    column.width = 220;
    [self.daysTable addTableColumn:column];
    daysScroll.documentView = self.daysTable;
    [content addSubview:daysScroll];

    // --- Dettaglio del giorno, a destra ---
    self.dayTitle = [self labelWithFont:[NSFont systemFontOfSize:16 weight:NSFontWeightBold]
                                  color:[XPTheme text]];
    self.dayTotal = [self labelWithFont:[NSFont monospacedDigitSystemFontOfSize:14
                                                                        weight:NSFontWeightBold]
                                  color:[XPTheme accent]];
    self.dayTotal.alignment = NSTextAlignmentRight;

    NSScrollView *detailScroll = [[NSScrollView alloc] init];
    detailScroll.translatesAutoresizingMaskIntoConstraints = NO;
    detailScroll.hasVerticalScroller = YES;
    detailScroll.borderType = NSNoBorder;
    detailScroll.drawsBackground = NO;

    NSView *detailContent = [[NSView alloc] init];
    detailContent.translatesAutoresizingMaskIntoConstraints = NO;

    self.entriesStack = [[NSStackView alloc] init];
    self.entriesStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.entriesStack.alignment = NSLayoutAttributeLeading;
    self.entriesStack.spacing = 4;
    self.entriesStack.translatesAutoresizingMaskIntoConstraints = NO;

    self.projectTotalsStack = [[NSStackView alloc] init];
    self.projectTotalsStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.projectTotalsStack.alignment = NSLayoutAttributeLeading;
    self.projectTotalsStack.spacing = 3;
    self.projectTotalsStack.translatesAutoresizingMaskIntoConstraints = NO;

    [detailContent addSubview:self.entriesStack];
    [detailContent addSubview:self.projectTotalsStack];
    detailScroll.documentView = detailContent;

    self.emptyLabel = [self labelWithFont:[XPTheme fontBody] color:[XPTheme textMuted]];
    self.emptyLabel.stringValue = NSLocalizedString(@"history.empty", nil);
    self.emptyLabel.alignment = NSTextAlignmentCenter;

    self.addButton = [XPButton buttonWithTitle:@"" style:XPButtonStyleGhost onClick:^(XPButton *b) {
        [self addEntryClicked:b];
    }];
    self.addButton.symbolName = @"plus";
    self.addButton.toolTip = NSLocalizedString(@"history.add", nil);
    self.addButton.translatesAutoresizingMaskIntoConstraints = NO;

    [content addSubview:self.dayTitle];
    [content addSubview:self.dayTotal];
    [content addSubview:self.addButton];
    [content addSubview:detailScroll];
    [content addSubview:self.emptyLabel];

    // --- Barra del riepilogo, in fondo ---
    NSView *reportBar = [[NSView alloc] init];
    reportBar.translatesAutoresizingMaskIntoConstraints = NO;
    reportBar.wantsLayer = YES;
    reportBar.layer.backgroundColor = [XPTheme surface].CGColor;
    reportBar.layer.cornerRadius = [XPTheme radiusMedium];
    reportBar.layer.borderWidth = 1.0;
    reportBar.layer.borderColor = [XPTheme border].CGColor;
    [content addSubview:reportBar];

    self.periodPicker = [[NSPopUpButton alloc] init];
    self.periodPicker.translatesAutoresizingMaskIntoConstraints = NO;
    self.periodPicker.target = self;
    self.periodPicker.action = @selector(reportSelectionChanged:);

    self.projectPicker = [[NSPopUpButton alloc] init];
    self.projectPicker.translatesAutoresizingMaskIntoConstraints = NO;
    self.projectPicker.target = self;
    self.projectPicker.action = @selector(reportSelectionChanged:);

    self.reportTotalLabel = [self labelWithFont:[NSFont monospacedDigitSystemFontOfSize:13
                                                                                weight:NSFontWeightBold]
                                          color:[XPTheme accent]];

    self.clipboardButton = [XPButton buttonWithTitle:@"" style:XPButtonStylePrimary onClick:^(XPButton *b) {
        [self copyReport];
    }];
    self.clipboardButton.symbolName = @"doc.on.doc";
    self.clipboardButton.translatesAutoresizingMaskIntoConstraints = NO;

    self.csvButton = [XPButton buttonWithTitle:@"" style:XPButtonStyleGhost onClick:^(XPButton *b) {
        [self saveCSV];
    }];
    self.csvButton.symbolName = @"tablecells";
    self.csvButton.translatesAutoresizingMaskIntoConstraints = NO;

    for (NSView *view in @[self.periodPicker, self.projectPicker,
                           self.reportTotalLabel, self.clipboardButton, self.csvButton]) {
        [reportBar addSubview:view];
    }

    [NSLayoutConstraint activateConstraints:@[
        [reportBar.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:12],
        [reportBar.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-12],
        [reportBar.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-12],
        [reportBar.heightAnchor constraintEqualToConstant:52],

        [self.periodPicker.leadingAnchor constraintEqualToAnchor:reportBar.leadingAnchor constant:12],
        [self.periodPicker.centerYAnchor constraintEqualToAnchor:reportBar.centerYAnchor],
        [self.periodPicker.widthAnchor constraintGreaterThanOrEqualToConstant:150],

        [self.projectPicker.leadingAnchor constraintEqualToAnchor:self.periodPicker.trailingAnchor
                                                          constant:8],
        [self.projectPicker.centerYAnchor constraintEqualToAnchor:reportBar.centerYAnchor],
        [self.projectPicker.widthAnchor constraintGreaterThanOrEqualToConstant:160],

        [self.reportTotalLabel.leadingAnchor constraintEqualToAnchor:self.projectPicker.trailingAnchor
                                                            constant:14],
        [self.reportTotalLabel.centerYAnchor constraintEqualToAnchor:reportBar.centerYAnchor],
        [self.reportTotalLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.csvButton.leadingAnchor
                                                                      constant:-10],

        [self.clipboardButton.trailingAnchor constraintEqualToAnchor:reportBar.trailingAnchor constant:-12],
        [self.clipboardButton.centerYAnchor constraintEqualToAnchor:reportBar.centerYAnchor],
        [self.clipboardButton.widthAnchor constraintGreaterThanOrEqualToConstant:190],
        [self.clipboardButton.heightAnchor constraintEqualToConstant:30],

        [self.csvButton.trailingAnchor constraintEqualToAnchor:self.clipboardButton.leadingAnchor constant:-8],
        [self.csvButton.centerYAnchor constraintEqualToAnchor:reportBar.centerYAnchor],
        [self.csvButton.widthAnchor constraintGreaterThanOrEqualToConstant:100],
        [self.csvButton.heightAnchor constraintEqualToConstant:30],
    ]];

    [NSLayoutConstraint activateConstraints:@[
        [daysScroll.topAnchor constraintEqualToAnchor:content.topAnchor constant:12],
        [daysScroll.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:8],
        [daysScroll.bottomAnchor constraintEqualToAnchor:reportBar.topAnchor constant:-12],
        [daysScroll.widthAnchor constraintEqualToConstant:236],

        [self.dayTitle.topAnchor constraintEqualToAnchor:content.topAnchor constant:18],
        [self.dayTitle.leadingAnchor constraintEqualToAnchor:daysScroll.trailingAnchor constant:16],

        [self.addButton.centerYAnchor constraintEqualToAnchor:self.dayTitle.centerYAnchor],
        [self.addButton.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-20],

        [self.dayTotal.centerYAnchor constraintEqualToAnchor:self.dayTitle.centerYAnchor],
        [self.dayTotal.trailingAnchor constraintEqualToAnchor:self.addButton.leadingAnchor constant:-12],
        [self.dayTotal.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.dayTitle.trailingAnchor
                                                                 constant:10],

        [detailScroll.topAnchor constraintEqualToAnchor:self.dayTitle.bottomAnchor constant:12],
        [detailScroll.leadingAnchor constraintEqualToAnchor:daysScroll.trailingAnchor constant:16],
        [detailScroll.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16],
        [detailScroll.bottomAnchor constraintEqualToAnchor:reportBar.topAnchor constant:-12],

        [detailContent.widthAnchor constraintEqualToAnchor:detailScroll.widthAnchor],

        [self.entriesStack.topAnchor constraintEqualToAnchor:detailContent.topAnchor],
        [self.entriesStack.leadingAnchor constraintEqualToAnchor:detailContent.leadingAnchor],
        [self.entriesStack.trailingAnchor constraintEqualToAnchor:detailContent.trailingAnchor],

        [self.projectTotalsStack.topAnchor constraintEqualToAnchor:self.entriesStack.bottomAnchor
                                                          constant:16],
        [self.projectTotalsStack.leadingAnchor constraintEqualToAnchor:detailContent.leadingAnchor],
        [self.projectTotalsStack.trailingAnchor constraintEqualToAnchor:detailContent.trailingAnchor],
        [self.projectTotalsStack.bottomAnchor constraintEqualToAnchor:detailContent.bottomAnchor
                                                             constant:-12],

        [self.emptyLabel.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],
        [self.emptyLabel.centerYAnchor constraintEqualToAnchor:content.centerYAnchor],
    ]];
}

- (NSTextField *)labelWithFont:(NSFont *)font color:(NSColor *)color {
    NSTextField *label = [[NSTextField alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.editable = NO; label.selectable = NO; label.bordered = NO;
    label.drawsBackground = NO;
    label.font = font; label.textColor = color;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    label.stringValue = @"";
    return label;
}

#pragma mark - Presentazione

- (void)present {
    [self reload];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)trackerDidChange:(NSNotification *)note {
    // Solo se la finestra è a video: altrimenti si ricostruirebbe una volta al
    // secondo per nulla.
    if (self.window.isVisible) [self reload];
}

- (void)themeDidChange:(NSNotification *)note {
    self.window.backgroundColor = [XPTheme bg];
    if (self.window.isVisible) [self reload];
}

#pragma mark - Riepilogo per il cliente

- (void)rebuildReportPickers {
    NSInteger period = MAX(0, self.periodPicker.indexOfSelectedItem);
    [self.periodPicker removeAllItems];
    for (XPReportPeriod p = XPReportPeriodToday; p <= XPReportPeriodAll; p++) {
        [self.periodPicker addItemWithTitle:[XPReport nameForPeriod:p]];
    }
    [self.periodPicker selectItemAtIndex:MIN(period, self.periodPicker.numberOfItems - 1)];

    NSString *previous = self.projectPicker.titleOfSelectedItem;
    [self.projectPicker removeAllItems];

    // Prima voce: tutti i progetti. Le altre vengono dai progetti tracciabili.
    NSMutableArray<NSString *> *keys = [NSMutableArray arrayWithObject:@""];
    [self.projectPicker addItemWithTitle:NSLocalizedString(@"report.allProjects", nil)];
    for (XPTrackableProject *project in [[XPTracker shared] allProjects]) {
        [self.projectPicker addItemWithTitle:project.name];
        [keys addObject:project.key];
    }
    self.reportProjectKeys = keys;

    if (previous && [self.projectPicker itemWithTitle:previous]) {
        [self.projectPicker selectItemWithTitle:previous];
    }

    self.clipboardButton.title = NSLocalizedString(@"report.copy", nil);
    self.csvButton.title = NSLocalizedString(@"report.csv", nil);
    [self updateReportTotal];
}

- (XPReportPeriod)selectedPeriod {
    return (XPReportPeriod)MAX(0, self.periodPicker.indexOfSelectedItem);
}

/// nil quando è selezionato "tutti i progetti".
- (NSString *)selectedProjectKey {
    NSInteger index = self.projectPicker.indexOfSelectedItem;
    if (index <= 0 || index >= (NSInteger)self.reportProjectKeys.count) return nil;
    return self.reportProjectKeys[index];
}

- (NSString *)selectedProjectName {
    return [self selectedProjectKey] ? self.projectPicker.titleOfSelectedItem : nil;
}

- (void)reportSelectionChanged:(id)sender {
    [self updateReportTotal];
}

- (void)updateReportTotal {
    NSTimeInterval total = [XPReport totalForPeriod:[self selectedPeriod]
                                         projectKey:[self selectedProjectKey]];
    NSUInteger count = [XPReport entriesForPeriod:[self selectedPeriod]
                                       projectKey:[self selectedProjectKey]].count;

    self.reportTotalLabel.stringValue =
        [NSString stringWithFormat:NSLocalizedString(@"report.summary", nil),
         [XPTimeEntry shortStringFromInterval:total], (unsigned long)count];

    BOOL hasData = (count > 0);
    self.clipboardButton.enabled = hasData;
    self.csvButton.enabled = hasData;
}

- (void)copyReport {
    NSString *text = [XPReport plainTextReportForPeriod:[self selectedPeriod]
                                             projectKey:[self selectedProjectKey]
                                            projectName:[self selectedProjectName]];

    NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
    [pasteboard clearContents];
    [pasteboard setString:text forType:NSPasteboardTypeString];

    // Conferma sul pulsante stesso: un avviso modale per un copia sarebbe
    // di troppo, ma senza riscontro non si capisce se è successo qualcosa.
    NSString *original = self.clipboardButton.title;
    self.clipboardButton.title = NSLocalizedString(@"report.copied", nil);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        self.clipboardButton.title = original;
    });
}

- (void)saveCSV {
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.allowedContentTypes = @[UTTypeCommaSeparatedText];

    NSDateFormatter *stamp = [[NSDateFormatter alloc] init];
    stamp.dateFormat = @"yyyy-MM-dd";
    stamp.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];

    NSString *project = [self selectedProjectName] ?: @"all-projects";
    // Il nome del progetto arriva da un percorso: le barre non possono finire
    // in un nome di file.
    project = [project stringByReplacingOccurrencesOfString:@"/" withString:@"-"];
    panel.nameFieldStringValue = [NSString stringWithFormat:@"%@-%@.csv",
                                  project, [stamp stringFromDate:[NSDate date]]];

    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK) return;
        NSString *csv = [XPReport csvReportForPeriod:[self selectedPeriod]
                                          projectKey:[self selectedProjectKey]];
        [csv writeToURL:panel.URL atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    }];
}

#pragma mark - Ricarica

- (void)reload {
    NSInteger selected = self.daysTable.selectedRow;
    NSDate *previouslySelected = (selected >= 0 && selected < (NSInteger)self.days.count)
        ? self.days[selected] : nil;

    [self rebuildReportPickers];
    self.days = [[XPTracker shared] daysWithEntries];

    // Il giorno corrente compare anche prima della prima sessione chiusa, se
    // c'è qualcosa in corso: altrimenti "oggi" sparirebbe dall'elenco.
    NSDate *today = [[NSCalendar currentCalendar] startOfDayForDate:[NSDate date]];
    if ([XPTracker shared].currentEntries.count > 0 && ![self.days containsObject:today]) {
        self.days = [@[today] arrayByAddingObjectsFromArray:self.days];
    }

    BOOL empty = (self.days.count == 0);
    self.emptyLabel.hidden = !empty;
    self.dayTitle.hidden = empty;
    self.dayTotal.hidden = empty;

    [self.daysTable reloadData];

    if (empty) {
        [self showDay:nil];
        return;
    }

    NSUInteger index = previouslySelected ? [self.days indexOfObject:previouslySelected] : 0;
    if (index == NSNotFound) index = 0;
    [self.daysTable selectRowIndexes:[NSIndexSet indexSetWithIndex:index]
                byExtendingSelection:NO];
    [self showDay:self.days[index]];
}

#pragma mark - Elenco dei giorni

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return self.days.count;
}

- (NSView *)tableView:(NSTableView *)tableView
   viewForTableColumn:(NSTableColumn *)tableColumn
                  row:(NSInteger)row {
    NSDate *day = self.days[row];

    NSView *cell = [[NSView alloc] init];
    NSTextField *name = [self labelWithFont:[XPTheme fontBody] color:[XPTheme text]];
    name.stringValue = [self.dayFormatter stringFromDate:day];

    NSTextField *total = [self labelWithFont:[NSFont monospacedDigitSystemFontOfSize:11
                                                                             weight:NSFontWeightMedium]
                                       color:[XPTheme textMuted]];
    total.stringValue = [XPTimeEntry shortStringFromInterval:
                         [[XPTracker shared] totalForDay:day]];

    [cell addSubview:name];
    [cell addSubview:total];

    [NSLayoutConstraint activateConstraints:@[
        [name.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:6],
        [name.topAnchor constraintEqualToAnchor:cell.topAnchor constant:5],
        [name.trailingAnchor constraintLessThanOrEqualToAnchor:cell.trailingAnchor constant:-6],
        [total.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:6],
        [total.topAnchor constraintEqualToAnchor:name.bottomAnchor constant:1],
    ]];
    return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    NSInteger row = self.daysTable.selectedRow;
    if (row >= 0 && row < (NSInteger)self.days.count) [self showDay:self.days[row]];
}

#pragma mark - Dettaglio del giorno

- (void)showDay:(NSDate *)day {
    self.selectedDay = day;
    for (NSStackView *stack in @[self.entriesStack, self.projectTotalsStack]) {
        for (NSView *view in [stack.arrangedSubviews copy]) {
            [stack removeArrangedSubview:view];
            [view removeFromSuperview];
        }
    }
    if (!day) { self.dayTitle.stringValue = @""; self.dayTotal.stringValue = @""; return; }

    self.dayTitle.stringValue = [self.dayFormatter stringFromDate:day];
    self.dayTotal.stringValue = [XPTimeEntry shortStringFromInterval:
                                 [[XPTracker shared] totalForDay:day]];

    NSArray<XPTimeEntry *> *entries = [[XPTracker shared] entriesForDay:day];

    // Le sessioni ancora aperte di quel giorno vanno mostrate insieme alle
    // altre, altrimenti oggi sembrerebbe vuoto finché non si preme stop.
    NSMutableArray<XPTimeEntry *> *all = [entries mutableCopy];
    NSCalendar *calendar = [NSCalendar currentCalendar];
    for (XPTimeEntry *open in [XPTracker shared].currentEntries) {
        if ([[calendar startOfDayForDate:open.startDate] isEqualToDate:day]) {
            [all insertObject:open atIndex:0];
        }
    }

    for (XPTimeEntry *entry in all) {
        // Una sessione ancora aperta non si corregge: la fine non c'è, e
        // metterci mano mentre il cronometro va vorrebbe dire scrivere sopra
        // un dato che sta cambiando. Prima si ferma.
        BOOL editable = !entry.isRunning && !entry.isPaused;
        CGFloat inset = editable ? 74 : 10;

        NSView *row = [XPTimerSectionView rowForEntry:entry
                                            formatter:self.timeFormatter
                                        trailingInset:inset];
        if (editable) [self addActionsTo:row forEntry:entry];

        [self.entriesStack addArrangedSubview:row];
        [row.widthAnchor constraintEqualToAnchor:self.entriesStack.widthAnchor].active = YES;
    }

    [self buildProjectTotalsForDay:day entries:all];
    [self buildCommitsForDay:day entries:all];
}

/// I commit fatti quel giorno, sotto i totali per progetto.
///
/// Si cercano solo nei progetti su cui quel giorno sono andate delle ore: un
/// elenco di tutti i repository del disco sarebbe un altro strumento, e su
/// sessantatré cartelle costerebbe sessantatré `git log` per aprire una
/// finestra.
- (void)buildCommitsForDay:(NSDate *)day entries:(NSArray<XPTimeEntry *> *)entries {
    if (entries.count == 0) return;

    // Le chiavi dei progetti toccati quel giorno, senza ripetizioni e
    // nell'ordine in cui compaiono: chi ha lavorato di più sta più in alto.
    NSMutableArray<NSString *> *keys = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSString *> *names = [NSMutableDictionary dictionary];
    for (XPTimeEntry *entry in entries) {
        NSString *key = entry.projectKey ?: @"";
        if (key.length == 0 || [keys containsObject:key]) continue;
        [keys addObject:key];
        names[key] = entry.projectName ?: key;
    }

    NSMutableArray<XPCommit *> *tutti = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSString *> *diChi = [NSMutableDictionary dictionary];
    for (NSString *key in keys) {
        NSString *path = [XPGitLog pathForProjectKey:key];
        if (!path) continue;
        for (XPCommit *commit in [XPGitLog commitsForPath:path onDay:day]) {
            [tutti addObject:commit];
            diChi[commit.shortHash ?: @""] = names[key];
        }
    }
    if (tutti.count == 0) return;

    [tutti sortUsingComparator:^NSComparisonResult(XPCommit *a, XPCommit *b) {
        return [b.date compare:a.date];
    }];

    NSTextField *title = [self labelWithFont:[NSFont systemFontOfSize:10
                                                               weight:NSFontWeightSemibold]
                                       color:[XPTheme textMuted]];
    title.stringValue = [NSLocalizedString(@"history.commits", nil) uppercaseString];
    [self.projectTotalsStack addArrangedSubview:title];

    for (XPCommit *commit in tutti) {
        NSTextField *row = [self labelWithFont:[XPTheme fontSmall] color:[XPTheme textSoft]];
        row.stringValue = [NSString stringWithFormat:@"%@  %@  ·  %@  ·  %@",
                           [self.timeFormatter stringFromDate:commit.date],
                           commit.shortHash ?: @"",
                           diChi[commit.shortHash ?: @""] ?: @"",
                           commit.subject ?: @""];
        // Il messaggio può essere lungo quanto vuole chi l'ha scritto: si
        // taglia alla fine invece di allargare la finestra.
        row.lineBreakMode = NSLineBreakByTruncatingTail;
        row.toolTip = commit.subject;
        [self.projectTotalsStack addArrangedSubview:row];
        [row.widthAnchor constraintEqualToAnchor:self.projectTotalsStack.widthAnchor].active = YES;
    }
}

/// I due pulsanti in fondo alla riga: correggi ed elimina.
///
/// Sono icone e non parole perché la riga è alta 34 punti e due etichette
/// tradotte in quindici lingue non ci stanno; il nome per esteso arriva nel
/// tooltip e da lì lo legge anche VoiceOver.
- (void)addActionsTo:(NSView *)row forEntry:(XPTimeEntry *)entry {
    NSButton *(^iconButton)(NSString *, NSString *, SEL) =
        ^(NSString *symbol, NSString *title, SEL action) {
        NSImage *image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:title];
        NSButton *button = [NSButton buttonWithImage:image target:self action:action];
        button.translatesAutoresizingMaskIntoConstraints = NO;
        button.bezelStyle = NSBezelStyleAccessoryBarAction;
        button.bordered = NO;
        button.toolTip = title;
        button.contentTintColor = [XPTheme textMuted];
        return button;
    };

    NSButton *edit = iconButton(@"pencil",
                                NSLocalizedString(@"history.edit", nil),
                                @selector(editEntryClicked:));
    NSButton *remove = iconButton(@"trash",
                                  NSLocalizedString(@"history.delete", nil),
                                  @selector(deleteEntryClicked:));

    // L'identificatore viaggia sul pulsante: la riga viene ricostruita a ogni
    // ricarica e un puntatore alla sessione punterebbe a un oggetto sostituito.
    edit.identifier = entry.identifier;
    remove.identifier = entry.identifier;

    [row addSubview:edit];
    [row addSubview:remove];

    [NSLayoutConstraint activateConstraints:@[
        [remove.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-10],
        [remove.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [remove.widthAnchor constraintEqualToConstant:24],

        [edit.trailingAnchor constraintEqualToAnchor:remove.leadingAnchor constant:-4],
        [edit.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [edit.widthAnchor constraintEqualToConstant:24],
    ]];
}

/// La sessione a cui punta un pulsante, cercata per identificatore.
- (XPTimeEntry *)entryWithIdentifier:(NSString *)identifier {
    if (!identifier) return nil;
    for (XPTimeEntry *entry in [[XPTracker shared] entriesForDay:self.selectedDay]) {
        if ([entry.identifier isEqualToString:identifier]) return entry;
    }
    return nil;
}

- (void)editEntryClicked:(NSButton *)sender {
    XPTimeEntry *entry = [self entryWithIdentifier:sender.identifier];
    if (!entry) return;
    [XPEntryEditor editEntry:entry forWindow:self.window done:^{
        [self reload];
    }];
}

- (void)deleteEntryClicked:(NSButton *)sender {
    XPTimeEntry *entry = [self entryWithIdentifier:sender.identifier];
    if (!entry) return;

    // ⚠️ Si chiede conferma perché non c'è un annulla: le ore cancellate non
    // si recuperano, e il pulsante sta a quattro punti da quello di modifica.
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = NSLocalizedString(@"history.delete.confirm", nil);
    alert.informativeText = entry.task.length > 0
        ? [NSString stringWithFormat:@"%@ · %@", entry.projectName ?: @"", entry.task]
        : (entry.projectName ?: @"");
    [alert addButtonWithTitle:NSLocalizedString(@"history.delete", nil)];
    [alert addButtonWithTitle:NSLocalizedString(@"btn.cancel", nil)];

    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response != NSAlertFirstButtonReturn) return;
        [[XPTracker shared] deleteEntry:entry];
        [self reload];
    }];
}

- (void)addEntryClicked:(id)sender {
    [XPEntryEditor addEntryOnDay:self.selectedDay forWindow:self.window done:^{
        [self reload];
    }];
}

/// Totali per progetto del giorno: quanto è andato su cosa.
- (void)buildProjectTotalsForDay:(NSDate *)day entries:(NSArray<XPTimeEntry *> *)entries {
    if (entries.count == 0) return;

    NSMutableDictionary<NSString *, NSNumber *> *totals = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSString *> *names = [NSMutableDictionary dictionary];
    for (XPTimeEntry *entry in entries) {
        NSString *key = entry.projectKey ?: @"";
        totals[key] = @(totals[key].doubleValue + entry.duration);
        names[key] = entry.projectName ?: key;
    }

    NSTextField *title = [self labelWithFont:[NSFont systemFontOfSize:10
                                                               weight:NSFontWeightSemibold]
                                       color:[XPTheme textMuted]];
    title.stringValue = [NSLocalizedString(@"history.byProject", nil) uppercaseString];
    [self.projectTotalsStack addArrangedSubview:title];

    NSArray *sorted = [totals keysSortedByValueUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
        return [b compare:a];
    }];

    for (NSString *key in sorted) {
        NSView *row = [[NSView alloc] init];
        row.translatesAutoresizingMaskIntoConstraints = NO;

        NSTextField *name = [self labelWithFont:[XPTheme fontSmall] color:[XPTheme textSoft]];
        name.stringValue = names[key];

        NSTextField *value = [self labelWithFont:[NSFont monospacedDigitSystemFontOfSize:10
                                                                                 weight:NSFontWeightMedium]
                                           color:[XPTheme text]];
        value.stringValue = [XPTimeEntry shortStringFromInterval:totals[key].doubleValue];
        value.alignment = NSTextAlignmentRight;

        [row addSubview:name];
        [row addSubview:value];
        [NSLayoutConstraint activateConstraints:@[
            [row.heightAnchor constraintEqualToConstant:18],
            [name.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:10],
            [name.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
            [value.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-10],
            [value.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
            [name.trailingAnchor constraintLessThanOrEqualToAnchor:value.leadingAnchor constant:-8],
        ]];

        [self.projectTotalsStack addArrangedSubview:row];
        [row.widthAnchor constraintEqualToAnchor:self.projectTotalsStack.widthAnchor].active = YES;
    }
}

@end
