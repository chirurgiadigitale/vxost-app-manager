//
//  XPNetwork.m
//

#import "XPNetwork.h"

#import <ifaddrs.h>
#import <arpa/inet.h>
#import <net/if.h>

@implementation XPNetwork

/// Legge le interfacce e restituisce indirizzo e nome della prima buona.
///
/// L'ordine in cui il sistema le elenca non è casuale: la prima IPv4 attiva,
/// non di loopback e non di un tunnel, è quella con cui la macchina esce.
/// Restituirle tutte non aiuterebbe: a chi legge serve un indirizzo da
/// digitare sul telefono, non un elenco fra cui scegliere.
+ (void)findAddress:(NSString **)outAddress interface:(NSString **)outInterface {
    if (outAddress) *outAddress = nil;
    if (outInterface) *outInterface = nil;

    struct ifaddrs *list = NULL;
    if (getifaddrs(&list) != 0) return;

    for (struct ifaddrs *entry = list; entry != NULL; entry = entry->ifa_next) {
        if (!entry->ifa_addr || entry->ifa_addr->sa_family != AF_INET) continue;
        if (!(entry->ifa_flags & IFF_UP)) continue;
        if (entry->ifa_flags & IFF_LOOPBACK) continue;

        NSString *name = @(entry->ifa_name);

        // ⚠️ utun e awdl vanno saltate. Sono i tunnel di sistema (VPN,
        // AirDrop, Continuity): hanno un indirizzo IPv4 valido e nessuno può
        // raggiungerci sopra un sito. Senza questo filtro il wizard mostra
        // l'indirizzo di AirDrop e chi lo digita sul telefono non trova nulla.
        if ([name hasPrefix:@"utun"] || [name hasPrefix:@"awdl"] ||
            [name hasPrefix:@"llw"]  || [name hasPrefix:@"bridge"]) continue;

        char buffer[INET_ADDRSTRLEN] = {0};
        struct sockaddr_in *address = (struct sockaddr_in *)entry->ifa_addr;
        if (!inet_ntop(AF_INET, &address->sin_addr, buffer, sizeof(buffer))) continue;

        NSString *text = @(buffer);
        if (text.length == 0 || [text hasPrefix:@"169.254."]) continue;   // senza DHCP

        if (outAddress) *outAddress = text;
        if (outInterface) *outInterface = name;
        break;
    }
    freeifaddrs(list);
}

+ (NSString *)localAddress {
    NSString *address = nil;
    [self findAddress:&address interface:NULL];
    return address;
}

+ (NSString *)localInterface {
    NSString *interface = nil;
    [self findAddress:NULL interface:&interface];
    return interface;
}

+ (BOOL)addressIsPrivate:(NSString *)address {
    NSArray<NSString *> *parts = [address componentsSeparatedByString:@"."];
    if (parts.count != 4) return NO;

    NSInteger first = parts[0].integerValue;
    NSInteger second = parts[1].integerValue;

    if (first == 10) return YES;                                  // 10.0.0.0/8
    if (first == 192 && second == 168) return YES;                // 192.168.0.0/16
    if (first == 172 && second >= 16 && second <= 31) return YES; // 172.16.0.0/12
    return NO;
}

@end
