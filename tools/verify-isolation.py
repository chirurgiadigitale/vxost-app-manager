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

Uso:
    python3 tools/verify-isolation.py <specchio> <payload> <radice-installazione>

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
    try:
        with open(percorso, "rb") as f:
            testa = f.read(4)
        return len(testa) == 4 and struct.unpack(">I", testa)[0] in MAGIE
    except OSError:
        return False


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
    if len(sys.argv) != 4:
        print("uso: verify-isolation.py <specchio> <payload> <radice-installazione>",
              file=sys.stderr)
        return 2
    specchio, payload, radice = (os.path.abspath(p).rstrip("/") for p in sys.argv[1:4])
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
    mancanti = 0
    estranee = 0
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
            for lib in libs:
                if not lib.startswith("/"):
                    # Nome senza percorso, come "libgd.dylib": lo risolve dyld
                    # a runtime con i suoi percorsi di ripiego. Viene dal build
                    # upstream, non da noi, e cambiarlo vorrebbe dire
                    # ricompilare: si segnala e si va avanti, invece di far
                    # fallire ogni build su una cosa che non dipende da noi.
                    senza_percorso.append((os.path.relpath(intero, payload), lib))
                    continue
                if lib.startswith(SISTEMA_LIB):
                    continue
                if lib.startswith(radice + "/"):
                    # Sta nel pacchetto? Dopo l'installazione quel percorso
                    # sara' questo file, e deve esserci.
                    atteso = os.path.join(payload, os.path.relpath(lib, radice))
                    if not os.path.exists(atteso):
                        mancanti += 1
                        problemi.append("%s dipende da %s, che il pacchetto non contiene"
                                        % (os.path.relpath(intero, payload), lib))
                    continue
                estranee += 1
                problemi.append("%s dipende da %s, fuori dal pacchetto e non di sistema"
                                % (os.path.relpath(intero, payload), lib))
    print("  %d Mach-O esaminati, %d dipendenze mancanti, %d estranee, %d nomi senza percorso"
          % (binari, mancanti, estranee, len(senza_percorso)))
    for dove, lib in senza_percorso[:5]:
        print("      %s -> %s (lo risolve dyld)" % (dove, lib))
    if len(senza_percorso) > 5:
        print("      e altri %d" % (len(senza_percorso) - 5))
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
