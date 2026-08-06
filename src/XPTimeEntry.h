//
//  XPTimeEntry.h
//  Una sessione di lavoro registrata.
//
//  Il tempo effettivo non è semplicemente fine meno inizio: le pause, sia
//  quelle premute a mano sia quelle decise dall'app per inattività, vanno
//  sottratte, altrimenti un pranzo dimenticato diventa lavoro fatturato.
//

#import <Foundation/Foundation.h>

@interface XPTimeEntry : NSObject

@property (nonatomic, copy)   NSString *identifier;
/// Chiave stabile del progetto: "vhost:4005" oppure "custom:<nome>".
@property (nonatomic, copy)   NSString *projectKey;
/// Nome mostrato, es. "guidaperbere/dist".
@property (nonatomic, copy)   NSString *projectName;
/// Descrizione facoltativa del task, es. "bugfix checkout".
@property (nonatomic, copy)   NSString *task;

@property (nonatomic, strong) NSDate *startDate;
/// nil finché la sessione è in corso.
@property (nonatomic, strong) NSDate *endDate;

/// Secondi complessivi trascorsi in pausa.
@property (nonatomic, assign) NSTimeInterval pausedSeconds;
/// Istante in cui è iniziata la pausa in corso; nil se non è in pausa.
@property (nonatomic, strong) NSDate *pauseStartedAt;

/// Durata al netto delle pause, aggiornata al secondo se la sessione è aperta.
- (NSTimeInterval)duration;

/// true se la sessione non è ancora stata chiusa.
- (BOOL)isRunning;
- (BOOL)isPaused;

/// Giorno di appartenenza, normalizzato a mezzanotte: serve a raggruppare.
- (NSDate *)day;

#pragma mark - Serializzazione

- (NSDictionary *)dictionaryRepresentation;
+ (instancetype)entryFromDictionary:(NSDictionary *)dictionary;

#pragma mark - Formattazione

/// Durata come "1h 45m", oppure "0h 44m".
+ (NSString *)shortStringFromInterval:(NSTimeInterval)interval;
/// Durata come "01:12:45", per il cronometro.
+ (NSString *)clockStringFromInterval:(NSTimeInterval)interval;

@end
