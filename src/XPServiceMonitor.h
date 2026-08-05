//
//  XPServiceMonitor.h
//  Tiene aggiornato lo stato dei tre servizi e notifica chi osserva.
//
//  Il polling rallenta quando il pannello è chiuso: da chiuso serve solo a
//  tenere corretta l'icona nella barra di stato.
//

#import <Foundation/Foundation.h>
#import "XPService.h"

extern NSString *const XPServicesDidChangeNotification;

@interface XPServiceMonitor : NSObject

+ (instancetype)shared;

@property (nonatomic, strong, readonly) NSArray<XPService *> *services;

/// true se almeno un servizio è attivo.
@property (nonatomic, readonly) BOOL anyRunning;
/// true se tutti e tre i servizi sono attivi.
@property (nonatomic, readonly) BOOL allRunning;
/// true se c'è una transizione in corso.
@property (nonatomic, readonly) BOOL anyBusy;

- (XPService *)serviceForKey:(NSString *)key;

/// Avvia il polling periodico.
- (void)start;

/// Passa alla cadenza rapida (pannello aperto) o lenta (pannello chiuso).
- (void)setFastPolling:(BOOL)fast;

/// Forza un aggiornamento immediato.
- (void)refreshNow;

@end
