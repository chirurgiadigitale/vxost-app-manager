//
//  XPLayout.h
//  Supporto al layout da destra a sinistra.
//
//  macOS specchia da solo le interfacce costruite con Auto Layout. Qui le
//  viste posizionano le sottoviste con coordinate esplicite, quindi in urdu
//  resterebbero da sinistra a destra con dentro un testo che si legge al
//  contrario. Questi due helper rendono il ribaltamento esplicito e locale,
//  senza riscrivere tutto il posizionamento.
//

#import <Cocoa/Cocoa.h>

/// true quando l'interfaccia va disposta da destra a sinistra.
BOOL XPIsRTL(void);

/// Specchia un rettangolo rispetto alla larghezza del contenitore.
/// In LTR lo restituisce invariato, così si può applicare sempre.
NSRect XPMirror(NSRect rect, CGFloat containerWidth);

/// Specchia una singola coordinata x di un elemento largo `width`.
CGFloat XPMirrorX(CGFloat x, CGFloat width, CGFloat containerWidth);

/// Stile di paragrafo con allineamento naturale: a sinistra in LTR, a destra
/// in RTL. Da usare per il testo disegnato a mano.
NSParagraphStyle *XPNaturalParagraphStyle(NSLineBreakMode lineBreakMode);
