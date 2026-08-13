//
//  XPTheme.m
//

#import "XPTheme.h"

NSString *const XPThemeDidChangeNotification = @"XPThemeDidChangeNotification";

static NSString *const XPThemeDefaultsKey = @"ThemePreference";

/// Costruisce un colore da esadecimale (#RRGGBB) con alpha opzionale.
static NSColor *Hex(uint32_t rgb, CGFloat alpha) {
    return [NSColor colorWithSRGBRed:((rgb >> 16) & 0xFF) / 255.0
                               green:((rgb >>  8) & 0xFF) / 255.0
                                blue:( rgb        & 0xFF) / 255.0
                               alpha:alpha];
}

/// Sceglie fra variante scura e chiara in base all'aspetto corrente.
static NSColor *Dyn(NSColor *dark, NSColor *light) {
    return [XPTheme isDark] ? dark : light;
}

@implementation XPTheme

#pragma mark - Preferenza

+ (XPThemePreference)preference {
    // Come nella dashboard, in assenza di scelta il tema scuro è il default
    // del design system, non l'impostazione di sistema.
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults objectForKey:XPThemeDefaultsKey] == nil) return XPThemePreferenceDark;
    return (XPThemePreference)[defaults integerForKey:XPThemeDefaultsKey];
}

+ (void)setPreference:(XPThemePreference)preference {
    [[NSUserDefaults standardUserDefaults] setInteger:preference forKey:XPThemeDefaultsKey];
    [self applyStoredPreference];
    [[NSNotificationCenter defaultCenter] postNotificationName:XPThemeDidChangeNotification
                                                        object:nil];
}

+ (void)applyStoredPreference {
    switch ([self preference]) {
        case XPThemePreferenceDark:
            NSApp.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
            break;
        case XPThemePreferenceLight:
            NSApp.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
            break;
        case XPThemePreferenceAuto:
            // appearance a nil restituisce il controllo a macOS.
            NSApp.appearance = nil;
            break;
    }
}

+ (NSString *)nameForPreference:(XPThemePreference)preference {
    switch (preference) {
        case XPThemePreferenceDark:  return NSLocalizedString(@"theme.dark", nil);
        case XPThemePreferenceLight: return NSLocalizedString(@"theme.light", nil);
        default:                     return NSLocalizedString(@"theme.auto", nil);
    }
}

#pragma mark - Aspetto corrente

+ (BOOL)isDark {
    NSAppearance *appearance = NSApp.effectiveAppearance;
    NSAppearanceName name = [appearance bestMatchFromAppearancesWithNames:@[
        NSAppearanceNameAqua, NSAppearanceNameDarkAqua
    ]];
    return [name isEqualToString:NSAppearanceNameDarkAqua];
}

#pragma mark - Superfici

+ (NSColor *)bg           { return Dyn(Hex(0x070B16, 1.0), Hex(0xF4F7FC, 1.0)); }
+ (NSColor *)bgElev       { return Dyn(Hex(0x0B1220, 1.0), Hex(0xFFFFFF, 1.0)); }
+ (NSColor *)surface      { return Dyn(Hex(0x94A3B8, 0.05), Hex(0x0F172A, 0.03)); }
+ (NSColor *)surface2     { return Dyn(Hex(0x94A3B8, 0.08), Hex(0x0F172A, 0.06)); }
+ (NSColor *)surfaceSolid { return Dyn(Hex(0x0F172A, 1.0), Hex(0xFFFFFF, 1.0)); }

#pragma mark - Testo

+ (NSColor *)text      { return Dyn(Hex(0xE9EFFA, 1.0), Hex(0x0B1220, 1.0)); }
+ (NSColor *)textSoft  { return Dyn(Hex(0xB7C3D6, 1.0), Hex(0x33415A, 1.0)); }
+ (NSColor *)textMuted { return Dyn(Hex(0x8493AB, 1.0), Hex(0x5A6B85, 1.0)); }

#pragma mark - Bordi

+ (NSColor *)border       { return Dyn(Hex(0x94A3B8, 0.16), Hex(0x0F172A, 0.12)); }
+ (NSColor *)borderStrong { return Dyn(Hex(0x94A3B8, 0.30), Hex(0x0F172A, 0.24)); }

#pragma mark - Accenti

+ (NSColor *)accent    { return Dyn(Hex(0xFD47FD, 1.0), Hex(0x5A15C9, 1.0)); }
+ (NSColor *)accentInk { return Dyn(Hex(0x0A0510, 1.0), Hex(0xFFFFFF, 1.0)); }
+ (NSColor *)cyan      { return Dyn(Hex(0xC79BFF, 1.0), Hex(0x6B21B8, 1.0)); }
+ (NSColor *)violet    { return Dyn(Hex(0xFC8A7E, 1.0), Hex(0xB03A1E, 1.0)); }
+ (NSColor *)amber     { return Dyn(Hex(0xFA8406, 1.0), Hex(0x7E4207, 1.0)); }
+ (NSColor *)danger    { return Dyn(Hex(0xFF5C5C, 1.0), Hex(0xA3200D, 1.0)); }
+ (NSColor *)running   { return Dyn(Hex(0x3FD68C, 1.0), Hex(0x0F7A47, 1.0)); }

#pragma mark - Tipografia

+ (NSFont *)fontTitle { return [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold]; }
+ (NSFont *)fontBody  { return [NSFont systemFontOfSize:12 weight:NSFontWeightMedium]; }
+ (NSFont *)fontSmall { return [NSFont systemFontOfSize:10 weight:NSFontWeightRegular]; }
+ (NSFont *)fontMono  { return [NSFont monospacedSystemFontOfSize:10 weight:NSFontWeightRegular]; }

#pragma mark - Raggi

+ (CGFloat)radiusSmall  { return 6.0; }
+ (CGFloat)radiusMedium { return 10.0; }
+ (CGFloat)radiusLarge  { return 14.0; }

@end
