//
//  XPPanelView.h
//  Contenuto del popover: intestazione, i tre servizi, azioni globali,
//  scorciatoie e footer.
//

#import <Cocoa/Cocoa.h>
#import "XPService.h"

@protocol XPPanelViewDelegate <NSObject>
- (void)panelDidToggleService:(XPService *)service;
- (void)panelDidRequestReload:(XPService *)service;
- (void)panelDidRequestStartAll;
- (void)panelDidRequestStopAll;
- (void)panelDidRequestRestart;
- (void)panelDidRequestOpenDashboard;
- (void)panelDidRequestOpenPhpMyAdmin;
- (void)panelDidRequestOpenHtdocs;
- (void)panelDidRequestOpenLogs;
- (void)panelDidRequestXamppAction:(NSString *)action confirmMessage:(NSString *)message;
- (void)panelDidRequestOpenFile:(NSString *)path;
- (void)panelDidRequestQuit;
@end


@interface XPPanelView : NSView

@property (nonatomic, weak) id<XPPanelViewDelegate> delegate;

/// Altezza necessaria a mostrare tutto il contenuto.
@property (nonatomic, readonly) CGFloat requiredHeight;

- (instancetype)initWithServices:(NSArray<XPService *> *)services;

/// Rilegge lo stato dei servizi e aggiorna le righe.
- (void)refresh;

/// Mostra un messaggio temporaneo nella barra di stato del pannello.
- (void)showMessage:(NSString *)message isError:(BOOL)isError;

@end
