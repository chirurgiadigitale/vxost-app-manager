//
//  XPTimerSectionView.m
//

#import "XPTimerSectionView.h"
#import "XPTheme.h"
#import "XPButton.h"
#import "XPTracker.h"
#import "XPTimeEntry.h"
#import "XPHistoryWindowController.h"

@interface XPTimerSectionView ()

/// Una riga per ogni sessione aperta: si lavora su più progetti insieme.
@property (nonatomic, strong) NSStackView *runningStack;

// Avvio di una nuova sessione
@property (nonatomic, strong) NSView *startCard;
@property (nonatomic, strong) NSPopUpButton *projectPicker;
@property (nonatomic, strong) NSTextField *taskField;
@property (nonatomic, strong) XPButton *startButton;

// Registrazioni di oggi e totale
@property (nonatomic, strong) NSStackView *entriesStack;
@property (nonatomic, strong) NSTextField *todayTotalLabel;
@property (nonatomic, strong) NSTextField *entriesTitle;
@property (nonatomic, strong) XPButton *historyButton;

@end


@implementation XPTimerSectionView

- (instancetype)init {
    if ((self = [super initWithFrame:NSZeroRect])) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        [self buildInterface];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(trackerDidChange:)
                                                     name:XPTrackerDidChangeNotification
                                                   object:nil];
        [self refresh];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Costruzione

- (void)buildInterface {
    NSStackView *root = [[NSStackView alloc] init];
    root.orientation = NSUserInterfaceLayoutOrientationVertical;
    root.alignment = NSLayoutAttributeLeading;
    root.spacing = 10;
    root.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:root];

    [NSLayoutConstraint activateConstraints:@[
        [root.topAnchor constraintEqualToAnchor:self.topAnchor],
        [root.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [root.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [root.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
    ]];

    // Sessioni in corso: una riga ciascuna, aggiunte e tolte a runtime.
    self.runningStack = [[NSStackView alloc] init];
    self.runningStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.runningStack.alignment = NSLayoutAttributeLeading;
    self.runningStack.spacing = 8;
    self.runningStack.translatesAutoresizingMaskIntoConstraints = NO;
    [root addArrangedSubview:self.runningStack];

    [root addArrangedSubview:[self buildStartCard]];
    [root addArrangedSubview:[self buildEntriesSection]];

    for (NSView *view in root.arrangedSubviews) {
        [view.widthAnchor constraintEqualToAnchor:root.widthAnchor].active = YES;
    }
}

/// Scheda per far partire una sessione.
- (NSView *)buildStartCard {
    NSView *card = [self cardView];

    self.projectPicker = [[NSPopUpButton alloc] init];
    self.projectPicker.translatesAutoresizingMaskIntoConstraints = NO;

    self.taskField = [[NSTextField alloc] init];
    self.taskField.translatesAutoresizingMaskIntoConstraints = NO;
    self.taskField.font = [XPTheme fontBody];
    self.taskField.bezelStyle = NSTextFieldRoundedBezel;

    self.startButton = [XPButton buttonWithTitle:@"" style:XPButtonStylePrimary onClick:^(XPButton *b) {
        [self startFromPicker];
    }];
    self.startButton.symbolName = @"play.fill";
    self.startButton.translatesAutoresizingMaskIntoConstraints = NO;

    [card addSubview:self.projectPicker];
    [card addSubview:self.taskField];
    [card addSubview:self.startButton];

    [NSLayoutConstraint activateConstraints:@[
        [self.projectPicker.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [self.projectPicker.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [self.projectPicker.widthAnchor constraintGreaterThanOrEqualToConstant:180],

        [self.taskField.leadingAnchor constraintEqualToAnchor:self.projectPicker.trailingAnchor
                                                     constant:8],
        [self.taskField.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        // Il campo della descrizione è l'unico elastico: allargando la
        // finestra cresce lui, non i pulsanti.
        [self.taskField.trailingAnchor constraintEqualToAnchor:self.startButton.leadingAnchor
                                                      constant:-8],

        [self.startButton.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
        [self.startButton.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [self.startButton.widthAnchor constraintGreaterThanOrEqualToConstant:96],
        [self.startButton.heightAnchor constraintEqualToConstant:28],

        [card.heightAnchor constraintEqualToConstant:56],
    ]];

    self.startCard = card;
    return card;
}

- (NSView *)buildEntriesSection {
    NSView *container = [[NSView alloc] init];
    container.translatesAutoresizingMaskIntoConstraints = NO;

    self.entriesTitle = [self labelWithFont:[NSFont systemFontOfSize:10
                                                              weight:NSFontWeightSemibold]
                                      color:[XPTheme textMuted]];
    self.todayTotalLabel = [self labelWithFont:[NSFont monospacedDigitSystemFontOfSize:11
                                                                               weight:NSFontWeightSemibold]
                                         color:[XPTheme text]];
    self.todayTotalLabel.alignment = NSTextAlignmentRight;

    self.historyButton = [XPButton buttonWithTitle:@"" style:XPButtonStyleQuiet onClick:^(XPButton *b) {
        [[XPHistoryWindowController shared] present];
    }];
    self.historyButton.symbolName = @"calendar";
    self.historyButton.translatesAutoresizingMaskIntoConstraints = NO;

    self.entriesStack = [[NSStackView alloc] init];
    self.entriesStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.entriesStack.alignment = NSLayoutAttributeLeading;
    self.entriesStack.spacing = 4;
    self.entriesStack.translatesAutoresizingMaskIntoConstraints = NO;

    [container addSubview:self.entriesTitle];
    [container addSubview:self.todayTotalLabel];
    [container addSubview:self.entriesStack];
    [container addSubview:self.historyButton];

    [NSLayoutConstraint activateConstraints:@[
        [self.entriesTitle.topAnchor constraintEqualToAnchor:container.topAnchor],
        [self.entriesTitle.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],

        [self.todayTotalLabel.centerYAnchor constraintEqualToAnchor:self.entriesTitle.centerYAnchor],
        [self.todayTotalLabel.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [self.todayTotalLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.entriesTitle.trailingAnchor
                                                                        constant:8],

        [self.entriesStack.topAnchor constraintEqualToAnchor:self.entriesTitle.bottomAnchor
                                                     constant:6],
        [self.entriesStack.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [self.entriesStack.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],

        [self.historyButton.topAnchor constraintEqualToAnchor:self.entriesStack.bottomAnchor
                                                      constant:6],
        [self.historyButton.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [self.historyButton.widthAnchor constraintGreaterThanOrEqualToConstant:190],
        [self.historyButton.heightAnchor constraintEqualToConstant:26],
        [self.historyButton.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
    ]];

    return container;
}

#pragma mark - Riga di una sessione in corso

- (NSView *)runningRowForEntry:(XPTimeEntry *)entry {
    NSView *card = [self cardView];
    BOOL paused = entry.isPaused;

    // Il bordo acceso distingue a colpo d'occhio ciò che sta correndo da ciò
    // che è in pausa, quando le sessioni aperte sono più di una.
    card.layer.borderColor = paused ? [XPTheme border].CGColor
                                    : [[XPTheme accent] colorWithAlphaComponent:0.55].CGColor;

    NSTextField *clock = [self labelWithFont:[NSFont monospacedDigitSystemFontOfSize:22
                                                                             weight:NSFontWeightBold]
                                       color:paused ? [XPTheme textMuted] : [XPTheme accent]];
    clock.stringValue = [XPTimeEntry clockStringFromInterval:entry.duration];

    NSTextField *project = [self labelWithFont:[XPTheme fontBody] color:[XPTheme text]];
    project.stringValue = entry.projectName ?: @"";

    NSTextField *task = [self labelWithFont:[XPTheme fontSmall] color:[XPTheme textMuted]];
    NSString *taskText = entry.task.length > 0 ? entry.task : NSLocalizedString(@"timer.noTask", nil);
    task.stringValue = paused
        ? [NSString stringWithFormat:@"%@ · %@", taskText, NSLocalizedString(@"timer.paused", nil)]
        : taskText;

    XPButton *pauseButton = [XPButton buttonWithTitle:
        paused ? NSLocalizedString(@"timer.resume", nil) : NSLocalizedString(@"timer.pause", nil)
                                                style:XPButtonStyleGhost
                                              onClick:^(XPButton *b) {
        if (paused) [[XPTracker shared] resumeEntry:entry];
        else        [[XPTracker shared] pauseEntry:entry];
    }];
    pauseButton.symbolName = paused ? @"play.fill" : @"pause.fill";
    pauseButton.translatesAutoresizingMaskIntoConstraints = NO;

    XPButton *stopButton = [XPButton buttonWithTitle:NSLocalizedString(@"timer.stop", nil)
                                               style:XPButtonStyleDanger
                                             onClick:^(XPButton *b) {
        [[XPTracker shared] stopEntry:entry];
    }];
    stopButton.symbolName = @"stop.fill";
    stopButton.translatesAutoresizingMaskIntoConstraints = NO;

    for (NSView *view in @[clock, project, task, pauseButton, stopButton]) {
        [card addSubview:view];
    }

    [NSLayoutConstraint activateConstraints:@[
        [card.heightAnchor constraintEqualToConstant:66],

        [clock.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [clock.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [clock.widthAnchor constraintEqualToConstant:104],

        [project.leadingAnchor constraintEqualToAnchor:clock.trailingAnchor constant:12],
        [project.topAnchor constraintEqualToAnchor:card.topAnchor constant:16],
        [project.trailingAnchor constraintLessThanOrEqualToAnchor:pauseButton.leadingAnchor
                                                         constant:-10],

        [task.leadingAnchor constraintEqualToAnchor:clock.trailingAnchor constant:12],
        [task.topAnchor constraintEqualToAnchor:project.bottomAnchor constant:1],
        [task.trailingAnchor constraintLessThanOrEqualToAnchor:pauseButton.leadingAnchor
                                                      constant:-10],

        [stopButton.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
        [stopButton.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [stopButton.widthAnchor constraintGreaterThanOrEqualToConstant:74],
        [stopButton.heightAnchor constraintEqualToConstant:28],

        [pauseButton.trailingAnchor constraintEqualToAnchor:stopButton.leadingAnchor constant:-8],
        [pauseButton.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [pauseButton.widthAnchor constraintGreaterThanOrEqualToConstant:86],
        [pauseButton.heightAnchor constraintEqualToConstant:28],
    ]];

    return card;
}

#pragma mark - Fabbriche

- (NSView *)cardView {
    NSView *card = [[NSView alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.wantsLayer = YES;
    card.layer.cornerRadius = [XPTheme radiusMedium];
    card.layer.backgroundColor = [XPTheme surface].CGColor;
    card.layer.borderWidth = 1.0;
    card.layer.borderColor = [XPTheme border].CGColor;
    return card;
}

- (NSTextField *)labelWithFont:(NSFont *)font color:(NSColor *)color {
    NSTextField *label = [[NSTextField alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.editable = NO;
    label.selectable = NO;
    label.bordered = NO;
    label.drawsBackground = NO;
    label.font = font;
    label.textColor = color;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    label.stringValue = @"";
    return label;
}

#pragma mark - Azioni

- (void)startFromPicker {
    NSInteger index = self.projectPicker.indexOfSelectedItem;
    NSArray<XPTrackableProject *> *projects = [[XPTracker shared] allProjects];

    // L'ultima voce del menu crea una voce nuova invece di sceglierne una.
    if (index == (NSInteger)projects.count + 1) {   // +1 per il separatore
        [self promptForCustomProject];
        return;
    }
    if (index < 0 || index >= (NSInteger)projects.count) return;

    [[XPTracker shared] startProject:projects[index] task:self.taskField.stringValue];
    self.taskField.stringValue = @"";
}

- (void)promptForCustomProject {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = NSLocalizedString(@"timer.newProject.title", nil);
    alert.informativeText = NSLocalizedString(@"timer.newProject.body", nil);
    [alert addButtonWithTitle:NSLocalizedString(@"timer.newProject.add", nil)];
    [alert addButtonWithTitle:NSLocalizedString(@"btn.cancel", nil)];

    NSTextField *input = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 24)];
    input.placeholderString = NSLocalizedString(@"timer.newProject.placeholder", nil);
    alert.accessoryView = input;
    [alert.window setInitialFirstResponder:input];

    if ([alert runModal] == NSAlertFirstButtonReturn) {
        XPTrackableProject *project = [[XPTracker shared] addCustomProjectNamed:input.stringValue];
        [self refresh];
        if (project) {
            NSArray<XPTrackableProject *> *projects = [[XPTracker shared] allProjects];
            NSUInteger index = [projects indexOfObject:project];
            if (index != NSNotFound) [self.projectPicker selectItemAtIndex:index];
        }
    }
}

#pragma mark - Aggiornamento

- (void)trackerDidChange:(NSNotification *)note {
    [self refresh];
}

- (void)refresh {
    XPTracker *tracker = [XPTracker shared];

    [self rebuildRunningRows:tracker.currentEntries];
    [self rebuildProjectPicker];

    self.startButton.title = NSLocalizedString(@"timer.start", nil);
    self.taskField.placeholderString = NSLocalizedString(@"timer.taskPlaceholder", nil);
    self.historyButton.title = NSLocalizedString(@"timer.history", nil);

    self.entriesTitle.stringValue = [NSLocalizedString(@"timer.todayEntries", nil) uppercaseString];

    NSDate *today = [NSDate date];
    self.todayTotalLabel.stringValue =
        [NSString stringWithFormat:NSLocalizedString(@"timer.todayTotal", nil),
         [XPTimeEntry shortStringFromInterval:[tracker totalForDay:today]]];

    [self rebuildEntriesForDay:today];
}

/// Ricostruisce le righe delle sessioni aperte.
///
/// Quando cambia solo il tempo si aggiornano i cronometri senza rifare le
/// viste: ricostruire tutto una volta al secondo farebbe perdere il fuoco ai
/// controlli e sfarfallare il pannello.
- (void)rebuildRunningRows:(NSArray<XPTimeEntry *> *)entries {
    if (self.runningStack.arrangedSubviews.count == entries.count) {
        BOOL onlyTimeChanged = YES;
        for (NSUInteger i = 0; i < entries.count; i++) {
            NSView *card = self.runningStack.arrangedSubviews[i];
            NSTextField *clock = nil;
            for (NSView *sub in card.subviews) {
                if ([sub isKindOfClass:[NSTextField class]]) { clock = (NSTextField *)sub; break; }
            }
            if (!clock) { onlyTimeChanged = NO; break; }
            clock.stringValue = [XPTimeEntry clockStringFromInterval:entries[i].duration];
        }
        if (onlyTimeChanged) return;
    }

    for (NSView *view in [self.runningStack.arrangedSubviews copy]) {
        [self.runningStack removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    for (XPTimeEntry *entry in entries) {
        NSView *row = [self runningRowForEntry:entry];
        [self.runningStack addArrangedSubview:row];
        [row.widthAnchor constraintEqualToAnchor:self.runningStack.widthAnchor].active = YES;
    }
}

- (void)rebuildProjectPicker {
    NSString *previous = self.projectPicker.titleOfSelectedItem;
    [self.projectPicker removeAllItems];

    XPTracker *tracker = [XPTracker shared];
    for (XPTrackableProject *project in [tracker allProjects]) {
        NSString *title = project.name;
        // Un progetto già in corso resta nell'elenco ma si vede che lo è.
        if ([tracker currentEntryForProjectKey:project.key]) {
            title = [NSString stringWithFormat:@"%@ ●", project.name];
        }
        [self.projectPicker addItemWithTitle:title];
    }
    [self.projectPicker.menu addItem:[NSMenuItem separatorItem]];
    [self.projectPicker addItemWithTitle:NSLocalizedString(@"timer.newProject", nil)];

    if (previous && [self.projectPicker itemWithTitle:previous]) {
        [self.projectPicker selectItemWithTitle:previous];
    }
}

- (void)rebuildEntriesForDay:(NSDate *)day {
    for (NSView *view in [self.entriesStack.arrangedSubviews copy]) {
        [self.entriesStack removeArrangedSubview:view];
        [view removeFromSuperview];
    }

    NSArray<XPTimeEntry *> *entries = [[XPTracker shared] entriesForDay:day];
    if (entries.count == 0) {
        NSTextField *empty = [self labelWithFont:[XPTheme fontSmall] color:[XPTheme textMuted]];
        empty.stringValue = NSLocalizedString(@"timer.noEntries", nil);
        [self.entriesStack addArrangedSubview:empty];
        return;
    }

    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateStyle = NSDateFormatterNoStyle;
    formatter.timeStyle = NSDateFormatterShortStyle;

    for (XPTimeEntry *entry in entries) {
        NSView *row = [XPTimerSectionView rowForEntry:entry formatter:formatter];
        [self.entriesStack addArrangedSubview:row];
        [row.widthAnchor constraintEqualToAnchor:self.entriesStack.widthAnchor].active = YES;
    }
}

+ (NSView *)rowForEntry:(id)rawEntry formatter:(NSDateFormatter *)formatter {
    return [self rowForEntry:rawEntry formatter:formatter trailingInset:10];
}

+ (NSView *)rowForEntry:(id)rawEntry
              formatter:(NSDateFormatter *)formatter
          trailingInset:(CGFloat)inset {
    XPTimeEntry *entry = rawEntry;
    NSView *row = [[NSView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    NSTextField *(^label)(NSFont *, NSColor *) = ^(NSFont *font, NSColor *color) {
        NSTextField *field = [[NSTextField alloc] init];
        field.translatesAutoresizingMaskIntoConstraints = NO;
        field.editable = NO; field.selectable = NO; field.bordered = NO;
        field.drawsBackground = NO;
        field.font = font; field.textColor = color;
        field.lineBreakMode = NSLineBreakByTruncatingTail;
        return field;
    };

    NSTextField *name = label([XPTheme fontBody], [XPTheme text]);
    name.stringValue = entry.task.length > 0
        ? [NSString stringWithFormat:@"%@, %@", entry.task, entry.projectName]
        : (entry.projectName ?: @"");

    NSTextField *duration = label([NSFont monospacedDigitSystemFontOfSize:11
                                                                   weight:NSFontWeightMedium],
                                  [XPTheme text]);
    duration.stringValue = [XPTimeEntry shortStringFromInterval:entry.duration];
    duration.alignment = NSTextAlignmentRight;

    NSTextField *range = label([XPTheme fontSmall], [XPTheme textMuted]);
    range.stringValue = [NSString stringWithFormat:@"%@, %@",
                         [formatter stringFromDate:entry.startDate],
                         entry.endDate ? [formatter stringFromDate:entry.endDate] : @"…"];
    range.alignment = NSTextAlignmentRight;

    [row addSubview:name];
    [row addSubview:duration];
    [row addSubview:range];

    [NSLayoutConstraint activateConstraints:@[
        [row.heightAnchor constraintEqualToConstant:34],

        [name.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:10],
        [name.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [name.trailingAnchor constraintLessThanOrEqualToAnchor:duration.leadingAnchor constant:-8],

        [duration.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-inset],
        [duration.topAnchor constraintEqualToAnchor:row.topAnchor constant:5],

        [range.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-inset],
        [range.topAnchor constraintEqualToAnchor:duration.bottomAnchor constant:0],
    ]];

    row.wantsLayer = YES;
    row.layer.cornerRadius = [XPTheme radiusSmall];
    row.layer.backgroundColor = [XPTheme surface].CGColor;
    return row;
}

@end
