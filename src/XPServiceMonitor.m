//
//  XPServiceMonitor.m
//

#import "XPServiceMonitor.h"

NSString *const XPServicesDidChangeNotification = @"XPServicesDidChangeNotification";

static const NSTimeInterval XPPollFast = 2.0;
static const NSTimeInterval XPPollSlow = 8.0;

@interface XPServiceMonitor ()
@property (nonatomic, strong) NSArray<XPService *> *services;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, assign) BOOL refreshing;
@property (nonatomic, assign) NSTimeInterval interval;
@end


@implementation XPServiceMonitor

+ (instancetype)shared {
    static XPServiceMonitor *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[XPServiceMonitor alloc] init]; });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _services = [XPService allServices];
        _queue    = dispatch_queue_create("it.equipedigitale.vxost-manager.monitor",
                                          DISPATCH_QUEUE_SERIAL);
        _interval = XPPollSlow;
    }
    return self;
}

#pragma mark - Ciclo di polling

- (void)start {
    [self refreshNow];
    [self rescheduleTimer];
}

- (void)setFastPolling:(BOOL)fast {
    NSTimeInterval wanted = fast ? XPPollFast : XPPollSlow;
    if (wanted == self.interval) return;
    self.interval = wanted;
    [self rescheduleTimer];
}

- (void)rescheduleTimer {
    [self.timer invalidate];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:self.interval
                                                 repeats:YES
                                                   block:^(NSTimer *t) { [self refreshNow]; }];
    // Deve continuare a scattare anche mentre un menu è aperto.
    [[NSRunLoop mainRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];
}

- (void)refreshNow {
    // Salta il giro se il precedente è ancora in corso: pgrep e i probe TCP
    // sono rapidi, ma su una macchina carica meglio non accodare lavoro.
    if (self.refreshing) return;
    self.refreshing = YES;

    dispatch_async(self.queue, ^{
        for (XPService *service in self.services) {
            [service refresh];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self.refreshing = NO;
            [[NSNotificationCenter defaultCenter] postNotificationName:XPServicesDidChangeNotification
                                                                object:self];
        });
    });
}

#pragma mark - Interrogazioni

- (XPService *)serviceForKey:(NSString *)key {
    for (XPService *s in self.services) {
        if ([s.key isEqualToString:key]) return s;
    }
    return nil;
}

- (BOOL)anyRunning {
    for (XPService *s in self.services) {
        if (s.state == XPServiceStateRunning) return YES;
    }
    return NO;
}

- (BOOL)allRunning {
    for (XPService *s in self.services) {
        if (s.state != XPServiceStateRunning) return NO;
    }
    return YES;
}

- (BOOL)anyBusy {
    for (XPService *s in self.services) {
        if (s.state == XPServiceStateBusy) return YES;
    }
    return NO;
}

@end
