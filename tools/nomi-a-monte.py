#!/usr/bin/env python3
"""Il pacchetto non nomina i prodotti da cui deriva.

Decisione di Davide, 16/09/2026: nello stack che si scarica non deve comparire
in nessun modo il nome dello stack di partenza ne' quello di chi lo compilava.

Due modi d'uso:

    nomi-a-monte.py riscrivi <cartella>...   sostituisce e poi verifica
    nomi-a-monte.py verifica <cartella>...   solo verifica, non scrive niente

⚠️ La sostituzione e' BYTE PER BYTE e a parita' di lunghezza, ed e' questo che
la rende sicura dentro un binario: nessun offset si sposta, nessuna stringa
serializzata cambia lunghezza dichiarata (pear.conf, s:N), nessun indice di un
.elc diventa falso. Le coppie hanno la stessa lunghezza per costruzione, e lo
script si ferma se non fosse cosi'.

⚠️ Va eseguito PRIMA della firma: modificare un Mach-O ne invalida la firma.

⚠️ Per i NOSTRI file (commenti, testi della dashboard, il testo del DMG) la
sostituzione automatica produrrebbe frasi senza senso, tipo "l'originale (da
VXOST)". Quelli si correggono alla fonte. Qui si trattano i binari e i file
ereditati, dove i nomi sono percorsi di build e di installazione.

La verifica e' insensibile alle maiuscole e guarda contenuti, nomi di file e
bersagli dei collegamenti. Esce 1 se trova anche una sola occorrenza, se non
riesce a leggere un file o una cartella, o se una grafia non e' fra quelle
previste: meglio una build ferma che un pacchetto creduto pulito.
"""
import os
import re
import stat
import sys

# Scritti spezzati: questo file sta nel repository, non nel pacchetto, ma cosi'
# nemmeno una ricerca su tutto il disco lo scambia per una menzione da togliere.
A = "xa" + "mpp"
B = "bit" + "nami"

COPPIE = [
    (A.upper().encode(), b"VXOST"),
    (A.capitalize().encode(), b"Vxost"),
    (A.encode(), b"vxost"),
    (B.upper().encode(), b"BUILDER"),
    (B.capitalize().encode(), b"Builder"),
    (B.encode(), b"builder"),
]
for vecchio, nuovo in COPPIE:
    assert len(vecchio) == len(nuovo), (vecchio, nuovo)

QUALSIASI = re.compile(("(?i)" + A + "|" + B).encode())


def voci(radici, errori):
    """Ogni voce sotto le radici, collegamenti compresi, senza seguirli."""
    for radice in radici:
        if not os.path.isdir(radice):
            errori.append("non e' una cartella: %s" % radice)
            continue
        yield radice
        for base, cartelle, file in os.walk(radice, onerror=lambda e: errori.append(str(e))):
            for n in cartelle + file:
                yield os.path.join(base, n)


def riscrivi_file(percorso, errori):
    """Sostituisce sul posto: stesso inode, stessi permessi, stessi hard link."""
    try:
        with open(percorso, "rb") as f:
            dati = f.read()
    except OSError as e:
        errori.append("illeggibile %s: %s" % (percorso, e))
        return 0
    if not QUALSIASI.search(dati):
        return 0
    nuovi = dati
    quante = 0
    for vecchio, nuovo in COPPIE:
        quante += nuovi.count(vecchio)
        nuovi = nuovi.replace(vecchio, nuovo)
    if len(nuovi) != len(dati):
        errori.append("la lunghezza e' cambiata, non scritto: %s" % percorso)
        return 0
    modo = os.stat(percorso).st_mode
    scrivibile = bool(modo & stat.S_IWUSR)
    try:
        if not scrivibile:
            os.chmod(percorso, modo | stat.S_IWUSR)
        with open(percorso, "r+b") as f:
            f.write(nuovi)
    except OSError as e:
        errori.append("non scrivibile %s: %s" % (percorso, e))
        return 0
    finally:
        if not scrivibile:
            os.chmod(percorso, modo)
    return quante


def riscrivi(radici):
    errori = []
    file_toccati = 0
    occorrenze = 0
    for v in voci(radici, errori):
        if os.path.islink(v):
            bersaglio = os.readlink(v)
            if QUALSIASI.search(bersaglio.encode()):
                nuovo = bersaglio.encode()
                for a, b in COPPIE:
                    nuovo = nuovo.replace(a, b)
                os.unlink(v)
                os.symlink(nuovo.decode(), v)
                file_toccati += 1
                occorrenze += 1
            continue
        if os.path.isfile(v):
            q = riscrivi_file(v, errori)
            if q:
                file_toccati += 1
                occorrenze += q
    print("  %d occorrenze riscritte in %d file" % (occorrenze, file_toccati))
    return errori


def verifica(radici):
    errori = []
    trovati = []
    esaminati = 0
    for v in voci(radici, errori):
        esaminati += 1
        if QUALSIASI.search(os.path.basename(v).encode()):
            trovati.append("nel nome: %s" % v)
        if os.path.islink(v):
            if QUALSIASI.search(os.readlink(v).encode()):
                trovati.append("nel bersaglio del collegamento: %s" % v)
            continue
        if os.path.isfile(v):
            try:
                with open(v, "rb") as f:
                    m = QUALSIASI.search(f.read())
            except OSError as e:
                errori.append("illeggibile %s: %s" % (v, e))
                continue
            if m:
                trovati.append("nel contenuto (%s): %s" % (m.group(0).decode(errors="replace"), v))
    for e in errori:
        print("!! %s" % e, file=sys.stderr)
    if trovati:
        print("!! %d voci nominano ancora lo stack di partenza o chi lo compilava:" % len(trovati), file=sys.stderr)
        for t in trovati[:30]:
            print("     " + t, file=sys.stderr)
        if len(trovati) > 30:
            print("     e altre %d" % (len(trovati) - 30), file=sys.stderr)
    if errori or trovati:
        return 1
    print("  %d voci esaminate, nessuna menzione" % esaminati)
    return 0


def main():
    if len(sys.argv) < 3 or sys.argv[1] not in ("riscrivi", "verifica"):
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    radici = sys.argv[2:]
    if sys.argv[1] == "riscrivi":
        errori = riscrivi(radici)
        for e in errori:
            print("!! %s" % e, file=sys.stderr)
        if errori:
            return 1
    return verifica(radici)


if __name__ == "__main__":
    sys.exit(main())
