//
//  XPLogWindowController.m
//

#import "XPLogWindowController.h"
#import "XPPaths.h"
#import "XPTheme.h"
#import "XPTaskRunner.h"

/// Quanto leggere dalla fine del file. 256 KB coprono ampiamente le ultime
/// centinaia di righe di qualsiasi log, restando istantanei anche su un file
/// da svariati gigabyte.
static const unsigned long long XPLogTailBytes = 256 * 1024;

@interface XPLogWindowController () <NSTextFieldDelegate>
@property (nonatomic, strong) NSPopUpButton *logSelector;
@property (nonatomic, strong) NSSearchField *filterField;
@property (nonatomic, strong) NSButton *autoRefreshCheckbox;
@property (nonatomic, strong) NSTextView *textView;
@property (nonatomic, strong) NSScrollView *scrollView;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) NSTimer *refreshTimer;
@property (nonatomic, strong) NSArray<NSDictionary *> *logs;
@property (nonatomic, strong) NSButton *elevateButton;
/// Percorsi già letti con privilegi in questa sessione: per non richiedere
/// la password a ogni aggiornamento, l'auto-refresh resta spento su questi.
@property (nonatomic, strong) NSMutableSet<NSString *> *elevatedPaths;
@end


@implementation XPLogWindowController

+ (instancetype)shared {
    static XPLogWindowController *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[XPLogWindowController alloc] init]; });
    return shared;
}

- (instancetype)init {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 860, 560)
                                                   styleMask:(NSWindowStyleMaskTitled |
                                                              NSWindowStyleMaskClosable |
                                                              NSWindowStyleMaskResizable |
                                                              NSWindowStyleMaskMiniaturizable)
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    window.title = NSLocalizedString(@"log.title", nil);
    window.titlebarAppearsTransparent = NO;
    window.releasedWhenClosed = NO;
    [window center];

    if ((self = [super initWithWindow:window])) {
        _elevatedPaths = [NSMutableSet set];
        [self buildInterface];
        // Ferma il polling quando la finestra si chiude: nessun lavoro inutile.
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(windowWillClose:)
                                                     name:NSWindowWillCloseNotification
                                                   object:window];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(themeDidChange:)
                                                     name:XPThemeDidChangeNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self.refreshTimer invalidate];
}

#pragma mark - Interfaccia

- (void)buildInterface {
    NSView *content = self.window.contentView;
    content.wantsLayer = YES;

    CGFloat barHeight = 44.0;

    // --- Barra superiore ---
    NSView *toolbar = [[NSView alloc] initWithFrame:NSMakeRect(0, NSHeight(content.bounds) - barHeight,
                                                               NSWidth(content.bounds), barHeight)];
    toolbar.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    toolbar.wantsLayer = YES;
    toolbar.layer.backgroundColor = [XPTheme bgElev].CGColor;
    [content addSubview:toolbar];

    self.logSelector = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(12, 9, 280, 25) pullsDown:NO];
    self.logSelector.target = self;
    self.logSelector.action = @selector(logSelectionChanged:);
    [toolbar addSubview:self.logSelector];

    self.filterField = [[NSSearchField alloc] initWithFrame:NSMakeRect(302, 9, 200, 25)];
    self.filterField.placeholderString = NSLocalizedString(@"log.filter", nil);
    self.filterField.target = self;
    self.filterField.action = @selector(filterChanged:);
    self.filterField.autoresizingMask = NSViewWidthSizable;
    [toolbar addSubview:self.filterField];

    self.autoRefreshCheckbox = [NSButton checkboxWithTitle:NSLocalizedString(@"log.autoRefresh", nil)
                                                     target:self
                                                     action:@selector(autoRefreshChanged:)];
    self.autoRefreshCheckbox.frame = NSMakeRect(NSWidth(content.bounds) - 210, 11, 90, 20);
    self.autoRefreshCheckbox.state = NSControlStateValueOn;
    self.autoRefreshCheckbox.autoresizingMask = NSViewMinXMargin;
    [toolbar addSubview:self.autoRefreshCheckbox];

    NSButton *revealButton = [NSButton buttonWithTitle:NSLocalizedString(@"log.reveal", nil)
                                                 target:self
                                                 action:@selector(revealInFinder:)];
    revealButton.frame = NSMakeRect(NSWidth(content.bounds) - 112, 9, 100, 25);
    revealButton.bezelStyle = NSBezelStyleRounded;
    revealButton.autoresizingMask = NSViewMinXMargin;
    [toolbar addSubview:revealButton];

    // --- Area di testo ---
    CGFloat statusHeight = 24.0;
    self.scrollView = [[NSScrollView alloc] initWithFrame:
                       NSMakeRect(0, statusHeight, NSWidth(content.bounds),
                                  NSHeight(content.bounds) - barHeight - statusHeight)];
    self.scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.scrollView.hasVerticalScroller = YES;
    self.scrollView.hasHorizontalScroller = YES;
    self.scrollView.autohidesScrollers = YES;
    self.scrollView.borderType = NSNoBorder;

    self.textView = [[NSTextView alloc] initWithFrame:self.scrollView.bounds];
    self.textView.editable = NO;
    self.textView.richText = NO;
    self.textView.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    self.textView.backgroundColor = [XPTheme bg];
    self.textView.textColor = [XPTheme textSoft];
    self.textView.drawsBackground = YES;
    self.textView.minSize = NSMakeSize(0, 0);
    self.textView.maxSize = NSMakeSize(FLT_MAX, FLT_MAX);
    self.textView.verticallyResizable = YES;
    self.textView.horizontallyResizable = YES;
    self.textView.autoresizingMask = NSViewWidthSizable;
    self.textView.textContainer.widthTracksTextView = NO;
    self.textView.textContainer.containerSize = NSMakeSize(FLT_MAX, FLT_MAX);

    self.scrollView.documentView = self.textView;
    [content addSubview:self.scrollView];

    // --- Barra di stato in basso ---
    self.statusLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(12, 4, NSWidth(content.bounds) - 24, 16)];
    self.statusLabel.editable = NO;
    self.statusLabel.bordered = NO;
    self.statusLabel.drawsBackground = NO;
    self.statusLabel.font = [XPTheme fontSmall];
    self.statusLabel.textColor = [XPTheme textMuted];
    self.statusLabel.autoresizingMask = NSViewWidthSizable;
    [content addSubview:self.statusLabel];

    // Compare solo sui log che l'utente non può leggere (il .err di MySQL
    // appartiene a _mysql ed è vietato in lettura agli altri utenti).
    self.elevateButton = [NSButton buttonWithTitle:NSLocalizedString(@"log.elevate", nil)
                                             target:self
                                             action:@selector(readWithPrivileges:)];
    self.elevateButton.frame = NSMakeRect(NSWidth(content.bounds) - 220, 1, 210, 22);
    self.elevateButton.bezelStyle = NSBezelStyleRounded;
    self.elevateButton.controlSize = NSControlSizeSmall;
    self.elevateButton.font = [NSFont systemFontOfSize:11];
    self.elevateButton.autoresizingMask = NSViewMinXMargin;
    self.elevateButton.hidden = YES;
    [content addSubview:self.elevateButton];
}

#pragma mark - Lettura privilegiata

- (void)readWithPrivileges:(id)sender {
    NSString *path = [self currentLogPath];
    if (!path) return;

    // Una sola richiesta di password, poi il contenuto resta finché l'utente
    // non ricarica: l'auto-refresh su questo file viene disattivato.
    NSString *command = [NSString stringWithFormat:@"/usr/bin/tail -c %llu '%@'",
                         XPLogTailBytes, path];

    self.statusLabel.stringValue = NSLocalizedString(@"log.readingElevated", nil);
    self.elevateButton.enabled = NO;

    [XPTaskRunner runPrivilegedShell:command completion:^(XPTaskResult *result) {
        self.elevateButton.enabled = YES;

        if (result.cancelled) {
            self.statusLabel.stringValue = NSLocalizedString(@"log.readCancelled", nil);
            return;
        }
        if (!result.succeeded) {
            self.statusLabel.stringValue = NSLocalizedString(@"log.readFailed", nil);
            return;
        }

        [self.elevatedPaths addObject:path];
        self.autoRefreshCheckbox.state = NSControlStateValueOff;
        [self updateTimer];

        self.textView.string = result.output ?: @"";
        self.elevateButton.hidden = YES;
        self.statusLabel.stringValue = [NSString stringWithFormat:
            NSLocalizedString(@"log.readElevatedDone", nil), path];
        [self scrollToBottom];
    }];
}

#pragma mark - Ciclo di vita

- (void)showWindowAndReload {
    [self reloadLogList];
    [self showWindow:nil];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    [self loadCurrentLog];
    [self updateTimer];
}

- (void)windowWillClose:(NSNotification *)note {
    [self.refreshTimer invalidate];
    self.refreshTimer = nil;
}

/// Qui basta riassegnare i colori: la finestra è fatta di controlli di sistema
/// più una sola area di testo, e ricostruirla perderebbe il punto di lettura.
- (void)themeDidChange:(NSNotification *)note {
    self.textView.backgroundColor = [XPTheme bg];
    self.textView.textColor = [XPTheme textSoft];
    self.statusLabel.textColor = [XPTheme textMuted];

    NSView *toolbar = self.logSelector.superview;
    toolbar.layer.backgroundColor = [XPTheme bgElev].CGColor;
    [self.window.contentView setNeedsDisplay:YES];
}

- (void)reloadLogList {
    NSMutableArray *all = [NSMutableArray array];
    [all addObjectsFromArray:[XPPaths systemLogs]];

    NSArray *projects = [XPPaths projectLogs];
    if (projects.count > 0) {
        [all addObject:@{@"separator": @YES}];
        [all addObjectsFromArray:projects];
    }
    self.logs = all;

    NSString *previous = self.logSelector.titleOfSelectedItem;
    [self.logSelector removeAllItems];

    for (NSDictionary *log in all) {
        if (log[@"separator"]) {
            [self.logSelector.menu addItem:[NSMenuItem separatorItem]];
        } else {
            [self.logSelector addItemWithTitle:log[@"title"]];
        }
    }

    // Mantiene la selezione fra un refresh dell'elenco e l'altro.
    if (previous && [self.logSelector itemWithTitle:previous]) {
        [self.logSelector selectItemWithTitle:previous];
    }
}

#pragma mark - Azioni

- (void)logSelectionChanged:(id)sender { [self loadCurrentLog]; }
- (void)filterChanged:(id)sender       { [self loadCurrentLog]; }

- (void)autoRefreshChanged:(id)sender  { [self updateTimer]; }

- (void)revealInFinder:(id)sender {
    NSString *path = [self currentLogPath];
    if (path) [[NSWorkspace sharedWorkspace] selectFile:path inFileViewerRootedAtPath:@""];
}

- (void)updateTimer {
    [self.refreshTimer invalidate];
    self.refreshTimer = nil;
    if (self.autoRefreshCheckbox.state == NSControlStateValueOn && self.window.isVisible) {
        self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *t) {
            [self loadCurrentLog];
        }];
    }
}

#pragma mark - Lettura

- (NSString *)currentLogPath {
    NSString *title = self.logSelector.titleOfSelectedItem;
    if (!title) return nil;
    for (NSDictionary *log in self.logs) {
        if ([log[@"title"] isEqualToString:title]) return log[@"path"];
    }
    return nil;
}

- (void)loadCurrentLog {
    NSString *path = [self currentLogPath];
    if (!path) return;

    NSString *filter = self.filterField.stringValue;

    // Ricorda se l'utente era in fondo: in tal caso segue il log, altrimenti
    // resta dove sta a leggere.
    BOOL wasAtBottom = [self scrollViewIsAtBottom];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        unsigned long long fileSize = 0;
        NSString *tail = [self readTailOfFile:path size:&fileSize];

        NSString *shown = tail;
        NSUInteger matched = 0;
        if (filter.length > 0 && tail) {
            NSMutableArray *keep = [NSMutableArray array];
            for (NSString *line in [tail componentsSeparatedByString:@"\n"]) {
                if ([line rangeOfString:filter options:NSCaseInsensitiveSearch].location != NSNotFound) {
                    [keep addObject:line];
                }
            }
            matched = keep.count;
            shown = [keep componentsJoinedByString:@"\n"];
        }

        NSString *status;
        BOOL unreadable = (tail == nil);
        if (unreadable) {
            status = [NSString stringWithFormat:
                      NSLocalizedString(@"log.unreadable", nil),
                      path.lastPathComponent];
        } else {
            NSString *sizeText = [NSByteCountFormatter stringFromByteCount:(long long)fileSize
                                                                countStyle:NSByteCountFormatterCountStyleFile];
            status = [NSString stringWithFormat:NSLocalizedString(@"log.tailNote", nil),
                      path, sizeText];
            if (filter.length > 0) {
                status = [status stringByAppendingFormat:NSLocalizedString(@"log.matchingLines", nil),
                          (unsigned long)matched];
            }
            if (fileSize > 500 * 1024 * 1024) {
                status = [status stringByAppendingString:NSLocalizedString(@"log.veryLarge", nil)];
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            // Se il file è già stato letto con privilegi, il contenuto a video
            // resta quello: sovrascriverlo con una stringa vuota sarebbe un
            // passo indietro.
            if (unreadable && [self.elevatedPaths containsObject:path]) return;

            self.textView.string = shown ?: @"";
            self.statusLabel.stringValue = status;
            self.elevateButton.hidden = !unreadable;
            if (wasAtBottom) [self scrollToBottom];
        });
    });
}

/// Legge gli ultimi XPLogTailBytes byte del file, allineando l'inizio a un
/// capo riga per non troncare la prima riga a metà.
- (NSString *)readTailOfFile:(NSString *)path size:(unsigned long long *)outSize {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!handle) return nil;

    NSData *data = nil;
    @try {
        unsigned long long size = [handle seekToEndOfFile];
        if (outSize) *outSize = size;

        unsigned long long offset = (size > XPLogTailBytes) ? (size - XPLogTailBytes) : 0;
        [handle seekToFileOffset:offset];
        data = [handle readDataOfLength:(NSUInteger)MIN(size - offset, XPLogTailBytes)];
    } @catch (NSException *exception) {
        return nil;
    } @finally {
        [handle closeFile];
    }

    if (!data) return nil;

    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!text) {
        // Alcuni log contengono byte non UTF-8: lossy invece di fallire.
        text = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding] ?: @"";
    }

    // Scarta la prima riga, quasi certamente tagliata a metà dall'offset.
    NSRange firstNewline = [text rangeOfString:@"\n"];
    if (firstNewline.location != NSNotFound && firstNewline.location + 1 < text.length) {
        text = [text substringFromIndex:firstNewline.location + 1];
    }
    return text;
}

#pragma mark - Scorrimento

- (BOOL)scrollViewIsAtBottom {
    NSClipView *clip = self.scrollView.contentView;
    CGFloat maxY = NSMaxY(clip.documentVisibleRect);
    CGFloat docHeight = NSHeight(((NSView *)self.scrollView.documentView).frame);
    return (docHeight - maxY) < 40.0;
}

- (void)scrollToBottom {
    [self.textView scrollRangeToVisible:NSMakeRange(self.textView.string.length, 0)];
}

@end
