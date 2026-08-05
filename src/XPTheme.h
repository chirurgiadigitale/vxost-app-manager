//
//  XPTheme.h
//  Design tokens portati dal design system della dashboard
//  (htdocs/dashboard/stylesheets/all.css) così i due prodotti hanno
//  esattamente gli stessi colori.
//
//  I colori seguono il tema di sistema: dark è il default del design system,
//  la variante light replica :root[data-theme="light"].
//

#import <Cocoa/Cocoa.h>

/// Preferenza di tema, come il selettore della dashboard.
typedef NS_ENUM(NSInteger, XPThemePreference) {
    XPThemePreferenceAuto = 0,  ///< segue macOS
    XPThemePreferenceDark,      ///< sempre scuro (il default del design system)
    XPThemePreferenceLight      ///< sempre chiaro
};

/// Inviata quando la preferenza cambia: le viste custom si ridisegnano.
extern NSString *const XPThemeDidChangeNotification;

@interface XPTheme : NSObject

#pragma mark - Preferenza

/// Preferenza salvata fra un avvio e l'altro.
+ (XPThemePreference)preference;
+ (void)setPreference:(XPThemePreference)preference;

/// Applica la preferenza salvata a NSApp. Da chiamare all'avvio.
+ (void)applyStoredPreference;

/// Nome leggibile della preferenza.
+ (NSString *)nameForPreference:(XPThemePreference)preference;

#pragma mark - Superfici

+ (NSColor *)bg;           // --bg
+ (NSColor *)bgElev;       // --bg-elev
+ (NSColor *)surface;      // --surface
+ (NSColor *)surface2;     // --surface-2
+ (NSColor *)surfaceSolid; // --surface-solid

#pragma mark - Testo

+ (NSColor *)text;         // --text
+ (NSColor *)textSoft;     // --text-soft
+ (NSColor *)textMuted;    // --text-muted

#pragma mark - Bordi

+ (NSColor *)border;       // --border
+ (NSColor *)borderStrong; // --border-strong

#pragma mark - Accenti

+ (NSColor *)accent;       // --accent    arancione ufficiale XAMPP
+ (NSColor *)accentInk;    // --accent-ink
+ (NSColor *)cyan;         // --cyan      dati e database
+ (NSColor *)violet;       // --violet    codice e tooling
+ (NSColor *)amber;        // --amber     avvisi
+ (NSColor *)danger;       // --danger    errori
+ (NSColor *)running;      // stato attivo (verde, unico colore fuori scala: lo stato
                           // "acceso" va letto a colpo d'occhio anche da daltonici
                           // insieme alla forma del pallino)

#pragma mark - Utilità

/// true se l'aspetto corrente è scuro.
+ (BOOL)isDark;

/// Font di sistema alle dimensioni usate dal pannello.
+ (NSFont *)fontTitle;
+ (NSFont *)fontBody;
+ (NSFont *)fontSmall;
+ (NSFont *)fontMono;

/// Raggi (--r-*)
+ (CGFloat)radiusSmall;
+ (CGFloat)radiusMedium;
+ (CGFloat)radiusLarge;

@end
