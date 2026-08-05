//
//  XPVHostRowView.h
//  Riga della sezione Progetti: porta, nome e azioni.
//

#import <Cocoa/Cocoa.h>
#import "XPVirtualHost.h"

@interface XPVHostRowView : NSView

@property (nonatomic, strong, readonly) XPVirtualHost *host;

- (instancetype)initWithHost:(XPVirtualHost *)host;

@end
