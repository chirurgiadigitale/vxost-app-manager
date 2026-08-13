//
//  XPProjectWizard.h
//  Creazione guidata di un progetto: cartella, virtual host, porta.
//
//  Aggiungere un progetto a mano vuol dire aprire httpd-vhosts.conf, scrivere
//  il blocco, cercare una porta libera in httpd.conf e riavviare Apache. Sono
//  quattro passaggi in tre posti diversi, e sbagliarne uno lascia giù tutti i
//  progetti locali finché non si trova l'errore.
//
//  La finestra raccoglie i dati e valida; il lavoro vero lo fa XPActions, che
//  è dove vivono tutte le operazioni dell'app.
//

#import <Cocoa/Cocoa.h>

@interface XPProjectWizard : NSWindowController

/// Presenta il wizard come foglio sulla finestra indicata.
/// Se la finestra è nil il wizard si apre come pannello a sé.
+ (void)presentFromWindow:(NSWindow *)parent;

@end
