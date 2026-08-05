//
//  main.m
//  XAMPP Manager — punto di ingresso.
//
//  L'app vive nella barra di stato: nessuna icona nel Dock, nessuna finestra
//  all'avvio.
//

#import <Cocoa/Cocoa.h>
#import "XPStatusController.h"
#import "XPServiceMonitor.h"

@interface XPAppDelegate : NSObject <NSApplicationDelegate>
@property (nonatomic, strong) XPStatusController *statusController;
@end

@implementation XPAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    self.statusController = [[XPStatusController alloc] init];
    [self.statusController install];
    [[XPServiceMonitor shared] start];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    // Chiudere la finestra dei log non deve chiudere l'app.
    return NO;
}

@end


int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        XPAppDelegate *delegate = [[XPAppDelegate alloc] init];
        app.delegate = delegate;

        // Accessory: presente nella barra di stato, assente dal Dock e dal
        // selettore applicazioni.
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [app run];
    }
    return 0;
}
