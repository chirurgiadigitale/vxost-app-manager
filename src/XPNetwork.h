//
//  XPNetwork.h
//  L'indirizzo del Mac sulla rete locale.
//
//  Serve a dire "i tuoi progetti si vedono su 192.168.1.126:4004" invece di
//  chiederlo a chi non ha motivo di saperlo.
//
//  ⚠️ Non è l'indirizzo del router. Il router è .1 della sua rete, e Apache
//  può mettersi in ascolto solo su un indirizzo che la macchina possiede: con
//  quello del router non parte affatto e dice "Cannot assign requested
//  address". È l'equivoco da cui è nata questa classe.
//

#import <Foundation/Foundation.h>

@interface XPNetwork : NSObject

/// L'indirizzo IPv4 del Mac sulla rete locale, nil se non è in rete.
///
/// Se ce n'è più di uno (cavo e wi-fi insieme) vince quello dell'interfaccia
/// che il sistema usa per uscire: è quello che risponde se qualcuno lo digita.
+ (NSString *)localAddress;

/// Il nome dell'interfaccia che porta quell'indirizzo, "en0" e simili.
+ (NSString *)localInterface;

/// L'indirizzo appartiene a una rete privata (10/8, 172.16/12, 192.168/16)?
///
/// ⚠️ Un Mac con un indirizzo pubblico non è dietro un router: aprire le porte
/// lì vuol dire aprirle a internet, non alla casa, e il testo che si mostra
/// deve dire una cosa diversa.
+ (BOOL)addressIsPrivate:(NSString *)address;

@end
