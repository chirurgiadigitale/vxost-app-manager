//
//  XPReport.m
//

#import "XPReport.h"
#import "XPGitLog.h"
#import "XPTracker.h"

@implementation XPReport

#pragma mark - Periodi

+ (NSDate *)startOfPeriod:(XPReportPeriod)period {
    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSDate *today = [calendar startOfDayForDate:[NSDate date]];

    switch (period) {
        case XPReportPeriodToday:
            return today;

        case XPReportPeriodThisWeek: {
            // Inizio settimana secondo le impostazioni locali: in Italia il
            // lunedì, altrove la domenica.
            NSDate *start = nil;
            [calendar rangeOfUnit:NSCalendarUnitWeekOfYear startDate:&start
                         interval:NULL forDate:today];
            return start ?: today;
        }
        case XPReportPeriodThisMonth: {
            NSDate *start = nil;
            [calendar rangeOfUnit:NSCalendarUnitMonth startDate:&start
                         interval:NULL forDate:today];
            return start ?: today;
        }
        case XPReportPeriodLastMonth: {
            NSDate *lastMonth = [calendar dateByAddingUnit:NSCalendarUnitMonth
                                                     value:-1 toDate:today options:0];
            NSDate *start = nil;
            [calendar rangeOfUnit:NSCalendarUnitMonth startDate:&start
                         interval:NULL forDate:lastMonth];
            return start ?: today;
        }
        case XPReportPeriodAll:
        default:
            return [NSDate distantPast];
    }
}

/// Fine del periodo, esclusa. Serve solo al mese scorso, che non arriva a oggi.
+ (NSDate *)endOfPeriod:(XPReportPeriod)period {
    if (period != XPReportPeriodLastMonth) return [NSDate distantFuture];

    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSDate *start = nil;
    [calendar rangeOfUnit:NSCalendarUnitMonth startDate:&start interval:NULL
                  forDate:[calendar startOfDayForDate:[NSDate date]]];
    return start ?: [NSDate distantFuture];
}

+ (NSString *)nameForPeriod:(XPReportPeriod)period {
    switch (period) {
        case XPReportPeriodToday:     return NSLocalizedString(@"report.period.today", nil);
        case XPReportPeriodThisWeek:  return NSLocalizedString(@"report.period.week", nil);
        case XPReportPeriodThisMonth: return NSLocalizedString(@"report.period.month", nil);
        case XPReportPeriodLastMonth: return NSLocalizedString(@"report.period.lastMonth", nil);
        default:                      return NSLocalizedString(@"report.period.all", nil);
    }
}

#pragma mark - Selezione

+ (NSArray<XPTimeEntry *> *)entriesForPeriod:(XPReportPeriod)period
                                  projectKey:(NSString *)projectKey {
    NSDate *start = [self startOfPeriod:period];
    NSDate *end = [self endOfPeriod:period];

    NSMutableArray<XPTimeEntry *> *result = [NSMutableArray array];
    XPTracker *tracker = [XPTracker shared];

    // Le sessioni ancora aperte contano: il riepilogo di oggi deve
    // comprendere il lavoro in corso, non solo quello già fermato.
    NSMutableArray<XPTimeEntry *> *candidates = [NSMutableArray array];
    for (NSDate *day in [tracker daysWithEntries]) {
        [candidates addObjectsFromArray:[tracker entriesForDay:day]];
    }
    [candidates addObjectsFromArray:tracker.currentEntries];

    for (XPTimeEntry *entry in candidates) {
        if ([entry.startDate compare:start] == NSOrderedAscending) continue;
        if ([entry.startDate compare:end] != NSOrderedAscending) continue;
        if (projectKey && ![entry.projectKey isEqualToString:projectKey]) continue;
        [result addObject:entry];
    }

    [result sortUsingComparator:^NSComparisonResult(XPTimeEntry *a, XPTimeEntry *b) {
        return [b.startDate compare:a.startDate];
    }];
    return result;
}

+ (NSTimeInterval)totalForPeriod:(XPReportPeriod)period projectKey:(NSString *)projectKey {
    NSTimeInterval total = 0;
    for (XPTimeEntry *entry in [self entriesForPeriod:period projectKey:projectKey]) {
        total += entry.duration;
    }
    return total;
}

#pragma mark - Testo per l'email

+ (NSString *)plainTextReportForPeriod:(XPReportPeriod)period
                            projectKey:(NSString *)projectKey
                           projectName:(NSString *)projectName {

    NSArray<XPTimeEntry *> *entries = [self entriesForPeriod:period projectKey:projectKey];

    NSDateFormatter *dayFormatter = [[NSDateFormatter alloc] init];
    dayFormatter.dateStyle = NSDateFormatterLongStyle;
    dayFormatter.timeStyle = NSDateFormatterNoStyle;

    NSDateFormatter *timeFormatter = [[NSDateFormatter alloc] init];
    timeFormatter.dateStyle = NSDateFormatterNoStyle;
    timeFormatter.timeStyle = NSDateFormatterShortStyle;

    NSMutableString *text = [NSMutableString string];

    // Intestazione: di chi si parla e di quale periodo.
    [text appendFormat:@"%@\n", projectName ?: NSLocalizedString(@"report.allProjects", nil)];
    [text appendFormat:@"%@\n", [self nameForPeriod:period]];
    [text appendString:@"\n"];

    if (entries.count == 0) {
        [text appendFormat:@"%@\n", NSLocalizedString(@"report.noEntries", nil)];
        return text;
    }

    // Raggruppate per giorno, dal più recente: è così che si legge un recap.
    //
    // __block è indispensabile: senza, il blocco qui sotto catturerebbe una
    // copia di queste variabili al momento in cui viene creato e continuerebbe
    // a vedere un giorno nullo e un elenco vuoto, stampando solo il totale.
    NSCalendar *calendar = [NSCalendar currentCalendar];
    __block NSDate *currentDay = nil;
    __block NSTimeInterval dayTotal = 0;
    __block NSMutableArray<NSString *> *dayLines = [NSMutableArray array];

    // Le chiavi dei progetti toccati in ogni giorno: servono a cercare i
    // commit solo dove si e' lavorato davvero.
    __block NSMutableOrderedSet<NSString *> *dayKeys = [NSMutableOrderedSet orderedSet];

    void (^flushDay)(void) = ^{
        if (!currentDay) return;
        [text appendFormat:@"%@, %@\n", [dayFormatter stringFromDate:currentDay],
         [XPTimeEntry shortStringFromInterval:dayTotal]];
        for (NSString *line in dayLines) [text appendFormat:@"%@\n", line];

        // I commit di quel giorno, sotto le ore. Un riepilogo che dice "4h 20m
        // su listeoo" non racconta niente a distanza di settimane; l'elenco
        // dei commit lo dice per intero, ed e' gia' scritto.
        NSMutableArray<XPCommit *> *commits = [NSMutableArray array];
        for (NSString *key in dayKeys) {
            NSString *path = [XPGitLog pathForProjectKey:key];
            if (!path) continue;
            [commits addObjectsFromArray:[XPGitLog commitsForPath:path onDay:currentDay]];
        }
        if (commits.count > 0) {
            [commits sortUsingComparator:^NSComparisonResult(XPCommit *a, XPCommit *b) {
                return [a.date compare:b.date];
            }];
            [text appendFormat:@"  %@\n", NSLocalizedString(@"history.commits", nil)];
            for (XPCommit *commit in commits) {
                [text appendFormat:@"    %@  %@  %@\n",
                 [timeFormatter stringFromDate:commit.date],
                 commit.shortHash ?: @"",
                 commit.subject ?: @""];
            }
        }
        [text appendString:@"\n"];
    };

    for (XPTimeEntry *entry in entries) {
        NSDate *day = [calendar startOfDayForDate:entry.startDate];
        if (!currentDay || ![day isEqualToDate:currentDay]) {
            flushDay();
            currentDay = day;
            dayTotal = 0;
            dayLines = [NSMutableArray array];
            dayKeys = [NSMutableOrderedSet orderedSet];
        }
        dayTotal += entry.duration;
        if (entry.projectKey) [dayKeys addObject:entry.projectKey];

        NSString *task = entry.task.length > 0 ? entry.task : entry.projectName;
        // Senza filtro per progetto il nome va ripetuto, o non si capisce a
        // cosa si riferisca la riga.
        if (!projectKey && entry.task.length > 0) {
            task = [NSString stringWithFormat:@"%@ (%@)", entry.task, entry.projectName];
        }

        [dayLines addObject:[NSString stringWithFormat:@"  %@, %@   %@   %@",
                             [timeFormatter stringFromDate:entry.startDate],
                             entry.endDate ? [timeFormatter stringFromDate:entry.endDate]
                                           : NSLocalizedString(@"report.ongoing", nil),
                             [XPTimeEntry shortStringFromInterval:entry.duration],
                             task ?: @""]];
    }
    flushDay();

    NSTimeInterval total = [self totalForPeriod:period projectKey:projectKey];
    [text appendFormat:@"%@: %@\n", NSLocalizedString(@"report.total", nil),
     [XPTimeEntry shortStringFromInterval:total]];

    return text;
}

#pragma mark - CSV

/// Racchiude un campo fra virgolette se contiene virgole, virgolette o a capo.
static NSString *CSVField(NSString *value) {
    NSString *text = value ?: @"";
    if ([text rangeOfCharacterFromSet:
         [NSCharacterSet characterSetWithCharactersInString:@",\"\n"]].location == NSNotFound) {
        return text;
    }
    return [NSString stringWithFormat:@"\"%@\"",
            [text stringByReplacingOccurrencesOfString:@"\"" withString:@"\"\""]];
}

+ (NSString *)csvReportForPeriod:(XPReportPeriod)period projectKey:(NSString *)projectKey {
    NSArray<XPTimeEntry *> *entries = [self entriesForPeriod:period projectKey:projectKey];

    // Formato ISO: un foglio di calcolo lo riconosce in qualunque lingua,
    // a differenza di una data scritta per esteso.
    NSDateFormatter *isoDay = [[NSDateFormatter alloc] init];
    isoDay.dateFormat = @"yyyy-MM-dd";
    isoDay.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];

    NSDateFormatter *isoTime = [[NSDateFormatter alloc] init];
    isoTime.dateFormat = @"HH:mm";
    isoTime.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];

    NSMutableString *csv = [NSMutableString string];
    [csv appendString:@"date,start,end,hours,project,task\n"];

    for (XPTimeEntry *entry in entries) {
        // Le ore in decimale sono ciò che serve per fatturare: 1,5 non 1h 30m.
        NSString *hours = [NSString stringWithFormat:@"%.2f", entry.duration / 3600.0];
        [csv appendFormat:@"%@,%@,%@,%@,%@,%@\n",
         [isoDay stringFromDate:entry.startDate],
         [isoTime stringFromDate:entry.startDate],
         entry.endDate ? [isoTime stringFromDate:entry.endDate] : @"",
         hours,
         CSVField(entry.projectName),
         CSVField(entry.task)];
    }
    return csv;
}

@end
