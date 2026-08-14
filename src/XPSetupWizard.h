//
//  XPSetupWizard.h
//  Le cinque domande del primo avvio.
//
//  Lingua, aspetto, password di MySQL, chi raggiunge i progetti, e un saluto.
//  Si vede una volta sola: dopo, la stessa roba sta nella finestra e nel menu.
//
//  ⚠️ Nessuna delle cinque è obbligatoria. Chi chiude la finestra si ritrova
//  esattamente lo stato di prima, che è uno stato che funziona: il wizard
//  propone, non installa.
//
//  ⛔ Le due cose che toccano il sistema, la password di MySQL e le direttive
//  Listen, si applicano **alla fine**, insieme, dopo aver detto cosa stanno
//  per fare. Applicarle passo per passo vorrebbe dire due richieste di
//  password in mezzo a un questionario, e chi si ferma a metà lascerebbe la
//  macchina in uno stato che non ha scelto.
//

#import <Cocoa/Cocoa.h>

@interface XPSetupWizard : NSWindowController

/// Il primo avvio è già avvenuto?
+ (BOOL)hasRun;

/// Mostra il wizard se non è mai stato mostrato. Da chiamare all'avvio.
+ (void)presentIfNeeded;

/// Mostra il wizard comunque. È la voce di menu, per chi vuole rifarlo.
+ (void)present;

@end
