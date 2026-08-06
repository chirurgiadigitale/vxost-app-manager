//
//  XPHistoryWindowController.m
//

#import "XPHistoryWindowController.h"
#import "XPTheme.h"
#import "XPTracker.h"
#import "XPTimeEntry.h"
#import "XPTimerSectionView.h"

@interface XPHistoryWindowController () <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, strong) NSTableView *daysTable;
@property (nonatomic, strong) NSArray<NSDate *> *days;
@property (nonatomic, strong) NSStackView *entriesStack;
@property (nonatomic, strong) NSStackView *projectTotalsStack;
@property (nonatomic, strong) NSTextField *dayTitle;
@property (nonatomic, strong) NSTextField *dayTotal;
@property (nonatomic, strong) NSTextField *emptyLabel;
@property (nonatomic, strong) NSDateFormatter *dayFormatter;
@property (nonatomic, strong) NSDateFormatter *timeFormatter;
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

    [content addSubview:self.dayTitle];
    [content addSubview:self.dayTotal];
    [content addSubview:detailScroll];
    [content addSubview:self.emptyLabel];

    [NSLayoutConstraint activateConstraints:@[
        [daysScroll.topAnchor constraintEqualToAnchor:content.topAnchor constant:12],
        [daysScroll.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:8],
        [daysScroll.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-12],
        [daysScroll.widthAnchor constraintEqualToConstant:236],

        [self.dayTitle.topAnchor constraintEqualToAnchor:content.topAnchor constant:18],
        [self.dayTitle.leadingAnchor constraintEqualToAnchor:daysScroll.trailingAnchor constant:16],

        [self.dayTotal.centerYAnchor constraintEqualToAnchor:self.dayTitle.centerYAnchor],
        [self.dayTotal.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-20],
        [self.dayTotal.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.dayTitle.trailingAnchor
                                                                 constant:10],

        [detailScroll.topAnchor constraintEqualToAnchor:self.dayTitle.bottomAnchor constant:12],
        [detailScroll.leadingAnchor constraintEqualToAnchor:daysScroll.trailingAnchor constant:16],
        [detailScroll.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16],
        [detailScroll.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-12],

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

- (void)reload {
    NSInteger selected = self.daysTable.selectedRow;
    NSDate *previouslySelected = (selected >= 0 && selected < (NSInteger)self.days.count)
        ? self.days[selected] : nil;

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
        NSView *row = [XPTimerSectionView rowForEntry:entry formatter:self.timeFormatter];
        [self.entriesStack addArrangedSubview:row];
        [row.widthAnchor constraintEqualToAnchor:self.entriesStack.widthAnchor].active = YES;
    }

    [self buildProjectTotalsForDay:day entries:all];
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
