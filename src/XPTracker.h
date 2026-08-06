//
//  XPTracker.h
//  Cronometro del tempo di lavoro, per progetto.
//
//  I progetti arrivano dai virtual host già rilevati, più le voci create a
//  mano per il lavoro che non è un sito locale (una call, una consulenza).
//
//  I dati stanno in un JSON leggibile sotto Application Support: sono ore di
//  lavoro, deve essere possibile aprirle, controllarle e portarle altrove
//  senza passare da questa app.
//

#import <Foundation/Foundation.h>
#import "XPTimeEntry.h"

/// Inviata a ogni cambiamento: avvio, pausa, ripresa, stop, tick del secondo.
extern NSString *const XPTrackerDidChangeNotification;

/// Un progetto tracciabile, che venga da un virtual host o creato a mano.
@interface XPTrackableProject : NSObject
@property (nonatomic, copy) NSString *key;    ///< "vhost:4005" o "custom:<nome>"
@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) BOOL isCustom;
@end


@interface XPTracker : NSObject

+ (instancetype)shared;

#pragma mark - Sessione in corso

/// nil se non si sta tracciando nulla.
@property (nonatomic, strong, readonly) XPTimeEntry *currentEntry;

- (void)startProject:(XPTrackableProject *)project task:(NSString *)task;
- (void)pause;
- (void)resume;
- (void)stop;

#pragma mark - Progetti

/// Virtual host rilevati più le voci create a mano, senza duplicati.
- (NSArray<XPTrackableProject *> *)allProjects;

/// Aggiunge una voce libera. Restituisce nil se il nome è vuoto o già presente.
- (XPTrackableProject *)addCustomProjectNamed:(NSString *)name;
- (void)removeCustomProjectWithKey:(NSString *)key;

#pragma mark - Storico

/// Sessioni chiuse del giorno indicato, dalla più recente.
- (NSArray<XPTimeEntry *> *)entriesForDay:(NSDate *)day;

/// Giorni con almeno una sessione, dal più recente.
- (NSArray<NSDate *> *)daysWithEntries;

/// Totale del giorno, sessione in corso compresa.
- (NSTimeInterval)totalForDay:(NSDate *)day;

/// Totale di un progetto nel giorno indicato.
- (NSTimeInterval)totalForProjectKey:(NSString *)key onDay:(NSDate *)day;

/// Totale di un progetto negli ultimi `days` giorni, oggi compreso.
- (NSTimeInterval)totalForProjectKey:(NSString *)key lastDays:(NSInteger)days;

/// Elimina una sessione dallo storico.
- (void)deleteEntry:(XPTimeEntry *)entry;

/// Percorso del file dei dati, mostrato nell'interfaccia.
- (NSString *)storagePath;

@end
