//
//  XPEntryEditor.m
//

#import "XPEntryEditor.h"
#import "XPTimeEntry.h"
#import "XPTracker.h"
#import "XPTheme.h"

/// Larghezza del foglio: sta comoda una descrizione di media lunghezza senza
/// coprire l'elenco che sta dietro.
static const CGFloat XPEditorWidth = 420;

@interface XPEntryEditor ()
@property (nonatomic, strong) NSWindow *sheet;
@property (nonatomic, strong) NSPopUpButton *projectPopup;
@property (nonatomic, strong) NSTextField *taskField;
@property (nonatomic, strong) NSDatePicker *startPicker;
@property (nonatomic, strong) NSDatePicker *endPicker;
@property (nonatomic, strong) NSTextField *errorLabel;
@property (nonatomic, strong) XPTimeEntry *entry;
@property (nonatomic, strong) NSDate *day;
@property (nonatomic, copy)   void (^done)(void);
@property (nonatomic, strong) NSArray<XPTrackableProject *> *projects;
/// Si trattiene da sé finché il foglio è aperto: senza questo l'oggetto
/// verrebbe rilasciato appena il metodo di classe ritorna, e i pulsanti
/// premuti dopo non troverebbero nessuno.
@property (nonatomic, strong) XPEntryEditor *retainSelf;
@end


@implementation XPEntryEditor

+ (void)editEntry:(XPTimeEntry *)entry
        forWindow:(NSWindow *)window
             done:(void (^)(void))done {
    if (!entry || !window) return;
    XPEntryEditor *editor = [[XPEntryEditor alloc] init];
    editor.entry = entry;
    editor.done = done;
    editor.retainSelf = editor;
    [editor presentOn:window title:NSLocalizedString(@"history.edit.title", nil)];
}

+ (void)addEntryOnDay:(NSDate *)day
            forWindow:(NSWindow *)window
                 done:(void (^)(void))done {
    if (!window) return;
    XPEntryEditor *editor = [[XPEntryEditor alloc] init];
    editor.day = day ?: [NSDate date];
    editor.done = done;
    editor.retainSelf = editor;
    [editor presentOn:window title:NSLocalizedString(@"history.add.title", nil)];
}

#pragma mark - Costruzione

- (NSTextField *)label:(NSString *)text {
    NSTextField *field = [[NSTextField alloc] init];
    field.translatesAutoresizingMaskIntoConstraints = NO;
    field.editable = NO; field.selectable = NO; field.bordered = NO;
    field.drawsBackground = NO;
    field.stringValue = text ?: @"";
    field.font = [NSFont systemFontOfSize:10 weight:NSFontWeightSemibold];
    field.textColor = [XPTheme textMuted];
    return field;
}

- (NSDatePicker *)timePicker {
    NSDatePicker *picker = [[NSDatePicker alloc] init];
    picker.translatesAutoresizingMaskIntoConstraints = NO;
    picker.datePickerStyle = NSDatePickerStyleTextFieldAndStepper;
    // Data e ora insieme: una sessione puo' essere stata ieri, e correggere
    // solo l'ora costringerebbe a cancellare e riscrivere per spostarla.
    picker.datePickerElements = NSDatePickerElementFlagYearMonthDay |
                                NSDatePickerElementFlagHourMinute;
    picker.target = self;
    picker.action = @selector(datesChanged:);
    return picker;
}

- (void)presentOn:(NSWindow *)parent title:(NSString *)title {
    NSView *content = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, XPEditorWidth, 300)];
    content.wantsLayer = YES;
    content.layer.backgroundColor = [XPTheme surfaceSolid].CGColor;

    NSTextField *heading = [[NSTextField alloc] init];
    heading.translatesAutoresizingMaskIntoConstraints = NO;
    heading.editable = NO; heading.selectable = NO; heading.bordered = NO;
    heading.drawsBackground = NO;
    heading.stringValue = title;
    heading.font = [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold];
    heading.textColor = [XPTheme text];

    // Il progetto si sceglie solo quando la sessione e' nuova: cambiarlo su
    // una gia' registrata sposterebbe ore da un totale a un altro, che e' una
    // cosa diversa dal correggere un orario e va chiesta esplicitamente.
    self.projects = [[XPTracker shared] allProjects];
    self.projectPopup = [[NSPopUpButton alloc] init];
    self.projectPopup.translatesAutoresizingMaskIntoConstraints = NO;
    for (XPTrackableProject *project in self.projects) {
        [self.projectPopup addItemWithTitle:project.name ?: @""];
    }
    self.projectPopup.enabled = (self.entry == nil);
    if (self.entry) {
        NSInteger index = [self indexOfProjectWithKey:self.entry.projectKey];
        if (index >= 0) {
            [self.projectPopup selectItemAtIndex:index];
        } else {
            // Il progetto non esiste piu' fra quelli rilevati: si mostra il
            // nome registrato allora, o la tendina direbbe il progetto
            // sbagliato su una sessione che non si puo' nemmeno spostare.
            [self.projectPopup addItemWithTitle:self.entry.projectName ?: @""];
            [self.projectPopup selectItemAtIndex:self.projectPopup.numberOfItems - 1];
        }
    }

    self.taskField = [[NSTextField alloc] init];
    self.taskField.translatesAutoresizingMaskIntoConstraints = NO;
    self.taskField.stringValue = self.entry.task ?: @"";
    self.taskField.placeholderString = NSLocalizedString(@"timer.taskPlaceholder", nil);

    self.startPicker = [self timePicker];
    self.endPicker   = [self timePicker];
    if (self.entry) {
        self.startPicker.dateValue = self.entry.startDate ?: [NSDate date];
        self.endPicker.dateValue   = self.entry.endDate ?: [NSDate date];
    } else {
        // Le ultime due ore, ai cinque minuti: chi registra a mano lo fa
        // quasi sempre per qualcosa appena finito.
        NSDate *now = [self roundedToFiveMinutes:[NSDate date]];
        self.endPicker.dateValue = [self time:now onDay:self.day];
        self.startPicker.dateValue = [self.endPicker.dateValue dateByAddingTimeInterval:-2 * 3600];
    }

    self.errorLabel = [self label:@""];
    self.errorLabel.textColor = [XPTheme danger];
    self.errorLabel.font = [NSFont systemFontOfSize:11];

    NSButton *cancel = [NSButton buttonWithTitle:NSLocalizedString(@"btn.cancel", nil)
                                          target:self action:@selector(cancel:)];
    cancel.translatesAutoresizingMaskIntoConstraints = NO;
    cancel.keyEquivalent = @"\033";                     // Esc

    NSButton *save = [NSButton buttonWithTitle:NSLocalizedString(@"history.save", nil)
                                        target:self action:@selector(save:)];
    save.translatesAutoresizingMaskIntoConstraints = NO;
    save.keyEquivalent = @"\r";                         // Invio

    NSTextField *projectLabel = [self label:NSLocalizedString(@"history.field.project", nil)];
    NSTextField *taskLabel    = [self label:NSLocalizedString(@"history.field.task", nil)];
    NSTextField *startLabel   = [self label:NSLocalizedString(@"history.field.start", nil)];
    NSTextField *endLabel     = [self label:NSLocalizedString(@"history.field.end", nil)];

    for (NSView *view in @[heading, projectLabel, self.projectPopup, taskLabel, self.taskField,
                           startLabel, self.startPicker, endLabel, self.endPicker,
                           self.errorLabel, cancel, save]) {
        [content addSubview:view];
    }

    const CGFloat pad = 20;
    [NSLayoutConstraint activateConstraints:@[
        [heading.topAnchor constraintEqualToAnchor:content.topAnchor constant:pad],
        [heading.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:pad],

        [projectLabel.topAnchor constraintEqualToAnchor:heading.bottomAnchor constant:18],
        [projectLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:pad],
        [self.projectPopup.topAnchor constraintEqualToAnchor:projectLabel.bottomAnchor constant:4],
        [self.projectPopup.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:pad],
        [self.projectPopup.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-pad],

        [taskLabel.topAnchor constraintEqualToAnchor:self.projectPopup.bottomAnchor constant:14],
        [taskLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:pad],
        [self.taskField.topAnchor constraintEqualToAnchor:taskLabel.bottomAnchor constant:4],
        [self.taskField.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:pad],
        [self.taskField.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-pad],

        [startLabel.topAnchor constraintEqualToAnchor:self.taskField.bottomAnchor constant:14],
        [startLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:pad],
        [self.startPicker.topAnchor constraintEqualToAnchor:startLabel.bottomAnchor constant:4],
        [self.startPicker.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:pad],

        [endLabel.topAnchor constraintEqualToAnchor:startLabel.topAnchor],
        [endLabel.leadingAnchor constraintEqualToAnchor:self.endPicker.leadingAnchor],
        [self.endPicker.topAnchor constraintEqualToAnchor:self.startPicker.topAnchor],
        [self.endPicker.leadingAnchor constraintEqualToAnchor:self.startPicker.trailingAnchor constant:16],

        [self.errorLabel.topAnchor constraintEqualToAnchor:self.startPicker.bottomAnchor constant:10],
        [self.errorLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:pad],
        [self.errorLabel.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-pad],

        [save.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-pad],
        [save.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-pad],
        [cancel.trailingAnchor constraintEqualToAnchor:save.leadingAnchor constant:-8],
        [cancel.bottomAnchor constraintEqualToAnchor:save.bottomAnchor],
        [save.topAnchor constraintGreaterThanOrEqualToAnchor:self.errorLabel.bottomAnchor constant:14],
    ]];

    self.sheet = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, XPEditorWidth, 300)
                                             styleMask:NSWindowStyleMaskTitled
                                               backing:NSBackingStoreBuffered
                                                 defer:NO];
    self.sheet.contentView = content;
    [parent beginSheet:self.sheet completionHandler:nil];
    [self.sheet makeFirstResponder:self.taskField];
}

#pragma mark - Azioni

- (void)datesChanged:(id)sender {
    // L'errore compare mentre si sposta l'orologio, non dopo aver premuto
    // Salva: si vede subito quale dei due estremi e' fuori posto.
    BOOL valid = [self.endPicker.dateValue compare:self.startPicker.dateValue] == NSOrderedDescending;
    self.errorLabel.stringValue = valid ? @"" : NSLocalizedString(@"history.invalidRange", nil);
}

- (void)cancel:(id)sender {
    [self close];
}

- (void)save:(id)sender {
    NSDate *start = self.startPicker.dateValue;
    NSDate *end   = self.endPicker.dateValue;
    if ([end compare:start] != NSOrderedDescending) {
        self.errorLabel.stringValue = NSLocalizedString(@"history.invalidRange", nil);
        return;
    }

    NSString *task = self.taskField.stringValue;
    BOOL ok;
    if (self.entry) {
        ok = [[XPTracker shared] updateEntry:self.entry start:start end:end task:task];
    } else {
        NSInteger index = self.projectPopup.indexOfSelectedItem;
        XPTrackableProject *project = (index >= 0 && index < (NSInteger)self.projects.count)
            ? self.projects[index] : nil;
        ok = [[XPTracker shared] addEntryForProject:project task:task start:start end:end] != nil;
    }

    if (!ok) {
        self.errorLabel.stringValue = NSLocalizedString(@"history.invalidRange", nil);
        return;
    }

    void (^done)(void) = self.done;
    [self close];
    if (done) done();
}

- (void)close {
    [self.sheet.sheetParent endSheet:self.sheet];
    [self.sheet orderOut:nil];
    self.retainSelf = nil;
}

#pragma mark - Utilità

- (NSInteger)indexOfProjectWithKey:(NSString *)key {
    for (NSUInteger i = 0; i < self.projects.count; i++) {
        if ([self.projects[i].key isEqualToString:key]) return (NSInteger)i;
    }
    return -1;
}

- (NSDate *)roundedToFiveMinutes:(NSDate *)date {
    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSDateComponents *parts = [calendar components:(NSCalendarUnitYear | NSCalendarUnitMonth |
                                                    NSCalendarUnitDay | NSCalendarUnitHour |
                                                    NSCalendarUnitMinute)
                                          fromDate:date];
    parts.minute = (parts.minute / 5) * 5;
    return [calendar dateFromComponents:parts] ?: date;
}

/// L'ora di `time` portata sul giorno `day`: il pannello si apre sul giorno
/// che si sta guardando nello storico, non su oggi.
- (NSDate *)time:(NSDate *)time onDay:(NSDate *)day {
    if (!day) return time;
    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSDateComponents *hm = [calendar components:(NSCalendarUnitHour | NSCalendarUnitMinute)
                                       fromDate:time];
    NSDateComponents *ymd = [calendar components:(NSCalendarUnitYear | NSCalendarUnitMonth |
                                                  NSCalendarUnitDay)
                                        fromDate:day];
    ymd.hour = hm.hour;
    ymd.minute = hm.minute;
    return [calendar dateFromComponents:ymd] ?: time;
}

@end
