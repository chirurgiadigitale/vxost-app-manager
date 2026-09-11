#!/usr/bin/env python3
"""Il pacchetto si regge da solo, o si appoggia all'installazione di chi lo costruisce?

Due domande distinte, e nessuna delle due ha risposta in `httpd -t`.

1. LA CONFIGURAZIONE. `httpd -t -D DUMP_INCLUDES` elenca i file di
   configurazione inclusi, e basta: moduli, DocumentRoot, certificati e log
   non compaiono. Una configurazione che carica un modulo da fuori supera
   quel controllo senza una parola. Qui si leggono le direttive che nominano
   un percorso e si guarda dove porta ciascuna.

2. LE LIBRERIE. I binari portano scritto dentro il percorso ASSOLUTO delle
   loro dipendenze, e il builder lo riscrive verso la radice di
   installazione. Avviare il binario da una cartella specchio non cambia
   quei riferimenti: carica le librerie dell'installazione vera, non quelle
   del pacchetto. Non e' un difetto da correggere, e' come funziona dyld —
   ma vuol dire che "ha funzionato in prova" non dimostra che il pacchetto
   sia completo. Quello che si puo' dimostrare, e qui si dimostra, e' che
   ogni dipendenza che non sia di sistema sta dentro il pacchetto: dopo
   l'installazione quei percorsi esisteranno, perche' li spediamo noi.

⚠️ E si distingue quello che rompiamo noi da quello che ereditiamo. Lo stack
   upstream e' pieno di dipendenze verso macchine che non esistono piu':
   /ade/b/2649109290/... e' la macchina di build di Oracle, /bitnami/... quella
   di chi ha compilato XAMPP, e postgresql/lib/libpq.5.dylib non c'e' nemmeno
   nell'installazione da cui copiamo. Sono cosi' da prima di noi e non si
   correggono senza ricompilare: farci fallire la build vuol dire non
   costruire mai piu'. Si elencano, e si ferma la build solo per le
   dipendenze che la SORGENTE aveva e il pacchetto no, cioe' quelle che il
   confezionamento ha perso per strada.

Uso:
    python3 tools/verify-isolation.py <specchio> <payload> <radice-installazione> [<sorgente>]

Esce 0 se non ci sono problemi, 1 se ce ne sono, 2 se non ha potuto guardare.
"""
import os
import re
import struct
import subprocess
import sys

# Le direttive che nominano un percorso, e in quale argomento sta.
# LoadModule ha il nome del modulo per primo; Alias l'indirizzo web.
DIRETTIVE = {
    "loadmodule": 2, "loadfile": 1, "include": 1, "includeoptional": 1,
    "serverroot": 1, "documentroot": 1, "errorlog": 1, "customlog": 1,
    "transferlog": 1, "pidfile": 1, "defaultruntimedir": 1, "typesconfig": 1,
    "mimemagicfile": 1, "alias": 2, "scriptalias": 2, "aliasmatch": 2,
    "scriptaliasmatch": 2, "authuserfile": 1, "authgroupfile": 1,
    "sslcertificatefile": 1, "sslcertificatekeyfile": 1,
    "sslcertificatechainfile": 1, "sslcacertificatefile": 1,
    "sslcacertificatepath": 1, "sslcarevocationfile": 1,
    "sslcarevocationpath": 1, "sslsessioncache": 1, "sslrandomseed": 2,
    "phpinidir": 1, "wsgiscriptalias": 2, "davlockdb": 1,
    "mutex": 0,  # "Mutex default:/percorso": l'argomento va spacchettato
}

# Percorsi che un server si aspetta dal sistema operativo e che il pacchetto
# non spedisce ne' deve spedire. Stretti di proposito: /tmp non c'e', perche'
# un DocumentRoot sotto /tmp sarebbe roba della macchina che costruisce, non
# una dipendenza di sistema.
SISTEMA_CONF = ("/usr/lib/", "/usr/share/", "/System/", "/Library/Frameworks/",
                "/dev/", "/var/run/", "/private/var/run/", "/etc/")
SISTEMA_LIB = ("/usr/lib/", "/System/", "/Library/Frameworks/")

MAGIE = (0xfeedface, 0xfeedfacf, 0xcefaedfe, 0xcffaedfe, 0xcafebabe, 0xbebafeca)


def e_mach_o(percorso):
    """⚠️ CA FE BA BE non basta: e' la firma dei binari universali Mach-O E
    quella dei .class di Java. share/gettext/javaversion.class ha fatto
    fallire la build dicendo che otool non rispondeva, il 11/09/2026.

    Dopo la firma, un .class porta la versione del formato (>= 45 per Java 1.0)
    dove un binario universale porta il numero di architetture, che e' un
    numero piccolo: nessuno spedisce un binario per 45 architetture."""
    try:
        with open(percorso, "rb") as f:
            testa = f.read(8)
    except OSError:
        return False
    if len(testa) < 4:
        return False
    magia = struct.unpack(">I", testa[:4])[0]
    if magia not in MAGIE:
        return False
    if magia in (0xcafebabe, 0xbebafeca) and len(testa) == 8:
        quante = struct.unpack(">I", testa[4:8])[0]
        if quante > 30:
            return False          # e' un .class di Java, non un fat binary
    return True


def percorsi_nella_configurazione(specchio):
    """Ogni percorso assoluto nominato da una direttiva attiva, con la riga."""
    trovati = []
    for cartella, _, nomi in os.walk(os.path.join(specchio, "etc")):
        for nome in sorted(nomi):
            if not nome.endswith((".conf", ".ini")):
                continue
            intero = os.path.join(cartella, nome)
            try:
                testo = open(intero, encoding="utf-8", errors="replace").read()
            except OSError as errore:
                trovati.append((intero, 0, None, str(errore)))
                continue
            for numero, riga in enumerate(testo.split("\n"), 1):
                pulita = riga.strip()
                if not pulita or pulita.startswith("#"):
                    continue
                pezzi = [p.strip('"') for p in pulita.split()]
                quale = DIRETTIVE.get(pezzi[0].lower())
                if quale is None:
                    continue
                if quale == 0:
                    # Mutex: "nome meccanismo:/percorso"
                    for pezzo in pezzi[1:]:
                        if ":" in pezzo and pezzo.split(":", 1)[1].startswith("/"):
                            trovati.append((intero, numero, pezzo.split(":", 1)[1], None))
                    continue
                if len(pezzi) <= quale:
                    continue
                valore = pezzi[quale]
                # Un CustomLog che comincia con | e' un programma, non un file.
                if valore.startswith("|"):
                    continue
                if valore.startswith("/"):
                    trovati.append((intero, numero, valore, None))
    return trovati


def dipendenze(percorso):
    """Le librerie che un Mach-O si porta scritte dentro."""
    try:
        uscita = subprocess.run(["otool", "-L", percorso], capture_output=True,
                                text=True, timeout=30)
    except (OSError, subprocess.SubprocessError) as errore:
        return None, str(errore)
    if uscita.returncode != 0:
        return None, (uscita.stderr or "otool ha risposto %d" % uscita.returncode).strip()
    fuori = []
    for riga in uscita.stdout.split("\n")[1:]:
        riga = riga.strip()
        if not riga:
            continue
        nome = riga.split(" (compatibility")[0].strip()
        if nome.startswith(("@rpath", "@loader_path", "@executable_path")):
            # Relativo al binario: non punta fuori dal pacchetto per
            # costruzione, e lo risolve dyld a partire da dove sta il file.
            continue
        fuori.append(nome)
    return fuori, None


def main():
    if len(sys.argv) not in (4, 5):
        print("uso: verify-isolation.py <specchio> <payload> <radice-installazione> [<sorgente>]",
              file=sys.stderr)
        return 2
    specchio, payload, radice = (os.path.abspath(p).rstrip("/") for p in sys.argv[1:4])
    sorgente = os.path.abspath(sys.argv[4]).rstrip("/") if len(sys.argv) > 4 else None
    for cartella in (specchio, payload):
        if not os.path.isdir(cartella):
            print("  %s non e' una cartella" % cartella, file=sys.stderr)
            return 2

    problemi = []

    # ---- 1. la configurazione ------------------------------------------
    esaminate = 0
    for file_conf, numero, valore, errore in percorsi_nella_configurazione(specchio):
        if errore:
            problemi.append("%s non si e' potuto leggere: %s" % (file_conf, errore))
            continue
        esaminate += 1
        if valore.startswith(specchio + "/") or valore == specchio:
            continue
        if valore.startswith(SISTEMA_CONF):
            continue
        problemi.append("%s:%d porta fuori dal pacchetto: %s"
                        % (os.path.relpath(file_conf, specchio), numero, valore))
    print("  %d percorsi nominati dalla configurazione, %d fuori"
          % (esaminate, len([p for p in problemi if "porta fuori" in p])))

    # ---- 2. le librerie ------------------------------------------------
    binari = 0
    perse = 0                 # c'erano nella sorgente e nel pacchetto no: colpa nostra
    ereditate = []            # rotte da prima di noi
    senza_percorso = []
    for cartella, _, nomi in os.walk(payload):
        for nome in nomi:
            intero = os.path.join(cartella, nome)
            if os.path.islink(intero) or not e_mach_o(intero):
                continue
            binari += 1
            libs, errore = dipendenze(intero)
            if libs is None:
                problemi.append("%s: otool non ha risposto (%s)"
                                % (os.path.relpath(intero, payload), errore))
                continue
            dove = os.path.relpath(intero, payload)
            for lib in libs:
                if not lib.startswith("/"):
                    # Nome senza percorso, come "libgd.dylib": lo risolve dyld
                    # a runtime con i suoi percorsi di ripiego. Viene dal build
                    # upstream e cambiarlo vorrebbe dire ricompilare.
                    senza_percorso.append((dove, lib))
                    continue
                if lib.startswith(SISTEMA_LIB):
                    continue
                if lib.startswith(radice + "/"):
                    # Dopo l'installazione quel percorso sara' questo file, e
                    # deve esserci. Se non c'e', la domanda e' di chi e' la
                    # colpa: la sorgente ce l'aveva?
                    relativo = os.path.relpath(lib, radice)
                    if os.path.exists(os.path.join(payload, relativo)):
                        continue
                    if sorgente and os.path.exists(os.path.join(sorgente, relativo)):
                        perse += 1
                        problemi.append("%s dipende da %s: c'era nella sorgente e il "
                                        "pacchetto non la contiene" % (dove, lib))
                    else:
                        ereditate.append((dove, lib))
                    continue
                # Un percorso assoluto che non e' ne' di sistema ne' nostro: la
                # macchina di build di qualcun altro. Se esiste qui e' un
                # riferimento all'installazione locale, ed e' un problema
                # nostro; se non esiste da nessuna parte e' cosi' da sempre.
                if os.path.exists(lib):
                    perse += 1
                    problemi.append("%s dipende da %s, che esiste solo su questa "
                                    "macchina" % (dove, lib))
                else:
                    ereditate.append((dove, lib))
    print("  %d Mach-O esaminati, %d dipendenze perse dal confezionamento"
          % (binari, perse))
    if senza_percorso:
        print("  %d dipendenze per nome, senza percorso: le risolve dyld"
              % len(senza_percorso))
        for dove, lib in senza_percorso[:3]:
            print("      %s -> %s" % (dove, lib))
        if len(senza_percorso) > 3:
            print("      e altre %d" % (len(senza_percorso) - 3))
    if ereditate:
        # Non un problema, ma nemmeno una cosa da nascondere: e' un elenco di
        # pezzi dello stack che non funzionerebbero se qualcuno li usasse.
        print("  %d dipendenze rotte gia' nella sorgente, ereditate da upstream:"
              % len(ereditate))
        visti = {}
        for dove, lib in ereditate:
            visti.setdefault(lib, []).append(dove)
        for lib in sorted(visti)[:6]:
            print("      %s (%d file)" % (lib, len(visti[lib])))
        if len(visti) > 6:
            print("      e altre %d librerie" % (len(visti) - 6))
    if binari == 0:
        problemi.append("nessun Mach-O trovato nel payload: non e' un pacchetto verificato")

    if problemi:
        sys.stdout.flush()
        print()
        for p in problemi[:20]:
            print("  " + p, file=sys.stderr)
        if len(problemi) > 20:
            print("  e altri %d" % (len(problemi) - 20), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
