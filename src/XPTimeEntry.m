//
//  XPTimeEntry.m
//

#import "XPTimeEntry.h"

@implementation XPTimeEntry

- (instancetype)init {
    if ((self = [super init])) {
        _identifier = [[NSUUID UUID] UUIDString];
    }
    return self;
}

#pragma mark - Durata

- (NSTimeInterval)duration {
    NSDate *end = self.endDate ?: [NSDate date];
    NSTimeInterval gross = [end timeIntervalSinceDate:self.startDate];

    NSTimeInterval paused = self.pausedSeconds;
    // Se la pausa è ancora aperta va contata fino a ora, altrimenti il
    // cronometro continuerebbe a correre durante la pausa stessa.
    if (self.pauseStartedAt) {
        paused += [end timeIntervalSinceDate:self.pauseStartedAt];
    }

    NSTimeInterval net = gross - paused;
    return net > 0 ? net : 0;
}

- (BOOL)isRunning { return self.endDate == nil; }
- (BOOL)isPaused  { return self.pauseStartedAt != nil; }

- (NSDate *)day {
    NSCalendar *calendar = [NSCalendar currentCalendar];
    return [calendar startOfDayForDate:self.startDate];
}

#pragma mark - Serializzazione

- (NSDictionary *)dictionaryRepresentation {
    NSMutableDictionary *dictionary = [NSMutableDictionary dictionary];
    dictionary[@"id"]          = self.identifier;
    dictionary[@"projectKey"]  = self.projectKey ?: @"";
    dictionary[@"projectName"] = self.projectName ?: @"";
    dictionary[@"task"]        = self.task ?: @"";
    // Secondi dal 1970: un formato che non dipende dal fuso orario né dalla
    // lingua, a differenza di una data formattata.
    dictionary[@"start"]       = @([self.startDate timeIntervalSince1970]);
    if (self.endDate)        dictionary[@"end"] = @([self.endDate timeIntervalSince1970]);
    if (self.pausedSeconds)  dictionary[@"paused"] = @(self.pausedSeconds);
    if (self.pauseStartedAt) dictionary[@"pauseStartedAt"] = @([self.pauseStartedAt timeIntervalSince1970]);
    return dictionary;
}

+ (instancetype)entryFromDictionary:(NSDictionary *)dictionary {
    if (![dictionary isKindOfClass:[NSDictionary class]]) return nil;

    NSNumber *start = dictionary[@"start"];
    if (![start isKindOfClass:[NSNumber class]]) return nil;   // senza inizio non è una sessione

    XPTimeEntry *entry = [[XPTimeEntry alloc] init];
    if ([dictionary[@"id"] isKindOfClass:[NSString class]]) entry.identifier = dictionary[@"id"];
    entry.projectKey  = dictionary[@"projectKey"];
    entry.projectName = dictionary[@"projectName"];
    entry.task        = dictionary[@"task"];
    entry.startDate   = [NSDate dateWithTimeIntervalSince1970:start.doubleValue];

    NSNumber *end = dictionary[@"end"];
    if ([end isKindOfClass:[NSNumber class]]) {
        entry.endDate = [NSDate dateWithTimeIntervalSince1970:end.doubleValue];
    }

    NSNumber *paused = dictionary[@"paused"];
    if ([paused isKindOfClass:[NSNumber class]]) entry.pausedSeconds = paused.doubleValue;

    NSNumber *pauseStart = dictionary[@"pauseStartedAt"];
    if ([pauseStart isKindOfClass:[NSNumber class]]) {
        entry.pauseStartedAt = [NSDate dateWithTimeIntervalSince1970:pauseStart.doubleValue];
    }
    return entry;
}

#pragma mark - Formattazione

+ (NSString *)shortStringFromInterval:(NSTimeInterval)interval {
    NSInteger total = (NSInteger)interval;
    return [NSString stringWithFormat:@"%ldh %02ldm", (long)(total / 3600), (long)((total % 3600) / 60)];
}

+ (NSString *)clockStringFromInterval:(NSTimeInterval)interval {
    NSInteger total = (NSInteger)interval;
    return [NSString stringWithFormat:@"%02ld:%02ld:%02ld",
            (long)(total / 3600), (long)((total % 3600) / 60), (long)(total % 60)];
}

@end
