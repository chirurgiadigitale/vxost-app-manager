//
//  XPTimerSectionView.m
//

#import "XPTimerSectionView.h"
#import "XPTheme.h"
#import "XPButton.h"
#import "XPTracker.h"
#import "XPTimeEntry.h"

@interface XPTimerSectionView ()

// Sessione in corso
@property (nonatomic, strong) NSView *currentCard;
@property (nonatomic, strong) NSTextField *clockLabel;
@property (nonatomic, strong) NSTextField *currentProjectLabel;
@property (nonatomic, strong) NSTextField *currentStateLabel;
@property (nonatomic, strong) XPButton *pauseButton;
@property (nonatomic, strong) XPButton *stopButton;

// Avvio di una nuova sessione
@property (nonatomic, strong) NSView *startCard;
@property (nonatomic, strong) NSPopUpButton *projectPicker;
@property (nonatomic, strong) NSTextField *taskField;
@property (nonatomic, strong) XPButton *startButton;

// Registrazioni e totale
@property (nonatomic, strong) NSStackView *entriesStack;
@property (nonatomic, strong) NSTextField *todayTotalLabel;
@property (nonatomic, strong) NSTextField *entriesTitle;

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
    root.distribution = NSStackViewDistributionFill;
    root.spacing = 10;
    root.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:root];

    [NSLayoutConstraint activateConstraints:@[
        [root.topAnchor constraintEqualToAnchor:self.topAnchor],
        [root.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [root.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [root.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
    ]];

    [root addArrangedSubview:[self buildCurrentCard]];
    [root addArrangedSubview:[self buildStartCard]];
    [root addArrangedSubview:[self buildEntriesSection]];

    // Le schede occupano tutta la larghezza disponibile, quale che sia.
    for (NSView *card in root.arrangedSubviews) {
        [card.widthAnchor constraintEqualToAnchor:root.widthAnchor].active = YES;
    }
}

/// Scheda della sessione in corso: cronometro, progetto, pausa e stop.
- (NSView *)buildCurrentCard {
    NSView *card = [self cardView];

    self.clockLabel = [self labelWithFont:[NSFont monospacedDigitSystemFontOfSize:30
                                                                          weight:NSFontWeightBold]
                                    color:[XPTheme text]];
    self.currentProjectLabel = [self labelWithFont:[XPTheme fontBody] color:[XPTheme textSoft]];
    self.currentStateLabel = [self labelWithFont:[XPTheme fontSmall] color:[XPTheme textMuted]];

    self.pauseButton = [XPButton buttonWithTitle:@"" style:XPButtonStyleGhost onClick:^(XPButton *b) {
        XPTracker *tracker = [XPTracker shared];
        if (tracker.currentEntry.isPaused) [tracker resume]; else [tracker pause];
    }];
    self.stopButton = [XPButton buttonWithTitle:@"" style:XPButtonStyleDanger onClick:^(XPButton *b) {
        [[XPTracker shared] stop];
    }];

    for (NSView *view in @[self.clockLabel, self.currentProjectLabel,
                           self.currentStateLabel, self.pauseButton, self.stopButton]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [card addSubview:view];
    }

    [NSLayoutConstraint activateConstraints:@[
        [self.clockLabel.topAnchor constraintEqualToAnchor:card.topAnchor constant:12],
        [self.clockLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],

        [self.currentProjectLabel.topAnchor constraintEqualToAnchor:self.clockLabel.bottomAnchor
                                                            constant:2],
        [self.currentProjectLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor
                                                                constant:14],
        [self.currentProjectLabel.trailingAnchor constraintLessThanOrEqualToAnchor:card.trailingAnchor
                                                                          constant:-14],

        [self.currentStateLabel.topAnchor constraintEqualToAnchor:self.currentProjectLabel.bottomAnchor
                                                          constant:1],
        [self.currentStateLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [self.currentStateLabel.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-12],

        // I comandi restano agganciati al bordo finale: crescendo la finestra
        // si allontanano dal cronometro invece di stirarsi.
        [self.stopButton.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
        [self.stopButton.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [self.stopButton.widthAnchor constraintGreaterThanOrEqualToConstant:74],
        [self.stopButton.heightAnchor constraintEqualToConstant:28],

        [self.pauseButton.trailingAnchor constraintEqualToAnchor:self.stopButton.leadingAnchor
                                                        constant:-8],
        [self.pauseButton.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [self.pauseButton.widthAnchor constraintGreaterThanOrEqualToConstant:82],
        [self.pauseButton.heightAnchor constraintEqualToConstant:28],

        [self.clockLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.pauseButton.leadingAnchor
                                                                 constant:-12],
    ]];

    self.currentCard = card;
    return card;
}

/// Scheda per far partire una sessione: progetto, descrizione, avvio.
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
        // Il campo della descrizione è l'unico elemento elastico: allargando
        // la finestra cresce lui, non i pulsanti.
        [self.taskField.trailingAnchor constraintEqualToAnchor:self.startButton.leadingAnchor
                                                      constant:-8],

        [self.startButton.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
        [self.startButton.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [self.startButton.widthAnchor constraintGreaterThanOrEqualToConstant:90],
        [self.startButton.heightAnchor constraintEqualToConstant:28],

        [card.heightAnchor constraintEqualToConstant:56],
    ]];

    self.startCard = card;
    return card;
}

/// Elenco delle registrazioni di oggi più il totale.
- (NSView *)buildEntriesSection {
    NSView *container = [[NSView alloc] init];
    container.translatesAutoresizingMaskIntoConstraints = NO;

    self.entriesTitle = [self labelWithFont:[NSFont systemFontOfSize:10
                                                              weight:NSFontWeightSemibold]
                                      color:[XPTheme textMuted]];
    self.todayTotalLabel = [self labelWithFont:[NSFont systemFontOfSize:11
                                                                weight:NSFontWeightSemibold]
                                         color:[XPTheme text]];
    self.todayTotalLabel.alignment = NSTextAlignmentRight;

    self.entriesStack = [[NSStackView alloc] init];
    self.entriesStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.entriesStack.alignment = NSLayoutAttributeLeading;
    self.entriesStack.spacing = 4;
    self.entriesStack.translatesAutoresizingMaskIntoConstraints = NO;

    [container addSubview:self.entriesTitle];
    [container addSubview:self.todayTotalLabel];
    [container addSubview:self.entriesStack];

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
        [self.entriesStack.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
    ]];

    return container;
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

    // L'ultima voce del menu crea un progetto nuovo invece di sceglierne uno.
    if (index == (NSInteger)projects.count) {
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
            // Selezione automatica del progetto appena creato: è quello su cui
            // si sta per lavorare.
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
    XPTimeEntry *current = tracker.currentEntry;

    // --- Sessione in corso ---
    self.currentCard.hidden = (current == nil);
    self.startCard.hidden = (current != nil);

    if (current) {
        self.clockLabel.stringValue = [XPTimeEntry clockStringFromInterval:current.duration];
        self.currentProjectLabel.stringValue = current.projectName ?: @"";
        self.currentStateLabel.stringValue = current.task.length > 0
            ? current.task
            : NSLocalizedString(@"timer.noTask", nil);

        BOOL paused = current.isPaused;
        self.clockLabel.textColor = paused ? [XPTheme textMuted] : [XPTheme accent];
        self.pauseButton.title = paused ? NSLocalizedString(@"timer.resume", nil)
                                        : NSLocalizedString(@"timer.pause", nil);
        self.pauseButton.symbolName = paused ? @"play.fill" : @"pause.fill";
        self.stopButton.title = NSLocalizedString(@"timer.stop", nil);
        self.stopButton.symbolName = @"stop.fill";

        if (paused) {
            self.currentStateLabel.stringValue =
                [NSString stringWithFormat:@"%@ · %@",
                 self.currentStateLabel.stringValue, NSLocalizedString(@"timer.paused", nil)];
        }
    } else {
        [self rebuildProjectPicker];
        self.startButton.title = NSLocalizedString(@"timer.start", nil);
        self.taskField.placeholderString = NSLocalizedString(@"timer.taskPlaceholder", nil);
    }

    // --- Registrazioni di oggi ---
    self.entriesTitle.stringValue = [NSLocalizedString(@"timer.todayEntries", nil) uppercaseString];

    NSDate *today = [NSDate date];
    NSTimeInterval total = [tracker totalForDay:today];
    self.todayTotalLabel.stringValue =
        [NSString stringWithFormat:NSLocalizedString(@"timer.todayTotal", nil),
         [XPTimeEntry shortStringFromInterval:total]];

    [self rebuildEntriesForDay:today];
}

- (void)rebuildProjectPicker {
    NSString *previous = self.projectPicker.titleOfSelectedItem;
    [self.projectPicker removeAllItems];

    for (XPTrackableProject *project in [[XPTracker shared] allProjects]) {
        [self.projectPicker addItemWithTitle:project.name];
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
        NSView *row = [self rowForEntry:entry formatter:formatter];
        [self.entriesStack addArrangedSubview:row];
        [row.widthAnchor constraintEqualToAnchor:self.entriesStack.widthAnchor].active = YES;
    }
}

- (NSView *)rowForEntry:(XPTimeEntry *)entry formatter:(NSDateFormatter *)formatter {
    NSView *row = [[NSView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    NSTextField *name = [self labelWithFont:[XPTheme fontBody] color:[XPTheme text]];
    name.stringValue = entry.task.length > 0
        ? [NSString stringWithFormat:@"%@ — %@", entry.task, entry.projectName]
        : entry.projectName;

    NSTextField *duration = [self labelWithFont:[NSFont monospacedDigitSystemFontOfSize:11
                                                                                weight:NSFontWeightMedium]
                                          color:[XPTheme text]];
    duration.stringValue = [XPTimeEntry shortStringFromInterval:entry.duration];
    duration.alignment = NSTextAlignmentRight;

    NSTextField *range = [self labelWithFont:[XPTheme fontSmall] color:[XPTheme textMuted]];
    range.stringValue = [NSString stringWithFormat:@"%@ – %@",
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

        [duration.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-10],
        [duration.topAnchor constraintEqualToAnchor:row.topAnchor constant:5],

        [range.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-10],
        [range.topAnchor constraintEqualToAnchor:duration.bottomAnchor constant:0],
    ]];

    row.wantsLayer = YES;
    row.layer.cornerRadius = [XPTheme radiusSmall];
    row.layer.backgroundColor = [XPTheme surface].CGColor;
    return row;
}

@end
