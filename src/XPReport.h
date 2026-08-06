//
//  XPReport.h
//  Riepiloghi esportabili delle ore lavorate.
//
//  Serve a mandare al cliente il conto delle ore: si sceglie un progetto e un
//  periodo e si ottiene un testo pronto da incollare in un'email, oppure un
//  CSV da allegare o da aprire in un foglio di calcolo.
//

#import <Foundation/Foundation.h>
#import "XPTimeEntry.h"

typedef NS_ENUM(NSInteger, XPReportPeriod) {
    XPReportPeriodToday = 0,
    XPReportPeriodThisWeek,
    XPReportPeriodThisMonth,
    XPReportPeriodLastMonth,
    XPReportPeriodAll
};

@interface XPReport : NSObject

/// Sessioni del periodo, filtrate per progetto se `projectKey` non è nil,
/// dalla più recente.
+ (NSArray<XPTimeEntry *> *)entriesForPeriod:(XPReportPeriod)period
                                  projectKey:(NSString *)projectKey;

/// Totale del periodo.
+ (NSTimeInterval)totalForPeriod:(XPReportPeriod)period
                      projectKey:(NSString *)projectKey;

/// Nome leggibile del periodo, tradotto.
+ (NSString *)nameForPeriod:(XPReportPeriod)period;

/// Estremi del periodo, per l'intestazione del riepilogo.
+ (NSDate *)startOfPeriod:(XPReportPeriod)period;

#pragma mark - Formati

/// Testo pronto da incollare in un'email: intestazione, sessioni raggruppate
/// per giorno, totale in fondo.
+ (NSString *)plainTextReportForPeriod:(XPReportPeriod)period
                            projectKey:(NSString *)projectKey
                           projectName:(NSString *)projectName;

/// CSV con una riga per sessione, separatore virgola e intestazione.
+ (NSString *)csvReportForPeriod:(XPReportPeriod)period
                      projectKey:(NSString *)projectKey;

@end
