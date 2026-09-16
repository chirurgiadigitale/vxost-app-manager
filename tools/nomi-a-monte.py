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
import bz2
import gzip
import importlib.util
import io
import lzma
import os
import re
import stat
import sys
import tarfile
import zipfile

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

# ⚠️ Pari lunghezza protegge gli offset, non le impronte. Il dodicesimo giro
# l'ha dimostrato su due formati: un PHAR riscritto usciva "nessuna menzione" e
# PHP lo rifiutava per firma interna invalida; uno ZIP eseguibile passava la
# verifica perche' i byte compressi non contengono il testo che si esegue.
# Da qui due regole: un archivio COMPRESSO che contiene i nomi nei byte non si
# riscrive (lo si rompe), e la verifica apre gli archivi invece di guardarne
# i byte.
COMPRESSI = [(b"PK\x03\x04", "zip"), (b"\x1f\x8b", "gzip"), (b"BZh", "bzip2"),
             (b"\xfd7zXZ", "xz"), (b"7z\xbc\xaf", "7z"), (b"\x28\xb5\x2f\xfd", "zstd")]


def _phar():
    qui = os.path.join(os.path.dirname(os.path.abspath(__file__)), "phar-impronte.py")
    spec = importlib.util.spec_from_file_location("phar_impronte", qui)
    modulo = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(modulo)
    return modulo


PHAR = _phar()


def formato_compresso(dati):
    for magia, nome in COMPRESSI:
        if dati.startswith(magia):
            return nome
    # ⚠️ Uno ZIP non deve cominciare con la sua firma: uno ZIP eseguibile ha
    # davanti "#!/usr/bin/env python3" e resta uno ZIP valido, perche' il
    # lettore parte dalla directory centrale in fondo. Il tredicesimo giro:
    # guardando solo il byte zero la verifica diceva "nessuna menzione" su un
    # archivio che eseguito stampava i due nomi, e la riscrittura ne rompeva il
    # CRC. is_zipfile cerca la directory centrale come fa il lettore.
    if b"PK\x05\x06" in dati[-65536 - 22:] and zipfile.is_zipfile(io.BytesIO(dati)):
        return "zip"
    return None


def menzioni_in_archivio(dati, profondita=0):
    """(trovato, descrizione) guardando DENTRO l'archivio. None se il formato
    non si sa aprire: chi chiama lo tratta come non verificato, non come pulito.
    Un livello di annidamento: un .jar dentro uno .zip viene aperto."""
    formato = formato_compresso(dati)
    if formato is None:
        m = QUALSIASI.search(dati)
        return (m is not None, m.group(0).decode(errors="replace") if m else "")
    if profondita > 2:
        return None
    try:
        if formato == "zip":
            with zipfile.ZipFile(io.BytesIO(dati)) as z:
                for info in z.infolist():
                    if QUALSIASI.search(info.filename.encode()):
                        return (True, "nome di voce: " + info.filename)
                    r = menzioni_in_archivio(z.read(info), profondita + 1)
                    if r is None:
                        return None
                    if r[0]:
                        return (True, info.filename + ": " + r[1])
            return (False, "")
        if formato in ("gzip", "bzip2", "xz"):
            aperto = {"gzip": gzip.decompress, "bzip2": bz2.decompress, "xz": lzma.decompress}[formato](dati)
            try:
                with tarfile.open(fileobj=io.BytesIO(aperto)) as tf:
                    for m in tf.getmembers():
                        if QUALSIASI.search(m.name.encode()) or QUALSIASI.search((m.linkname or "").encode()):
                            return (True, "nome di voce: " + m.name)
                        if m.isfile():
                            r = menzioni_in_archivio(tf.extractfile(m).read(), profondita + 1)
                            if r is None:
                                return None
                            if r[0]:
                                return (True, m.name + ": " + r[1])
                return (False, "")
            except tarfile.TarError:
                return menzioni_in_archivio(aperto, profondita + 1)
    except Exception:
        return None
    return None                       # 7z, zstd: la libreria standard non li apre


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
    formato = formato_compresso(dati) or ("phar" if PHAR.e_phar(dati) else None)
    if formato:
        # Un archivio con un'impronta o un CRC interno non si riscrive: lo si
        # romperebbe. Nel pacchetto del 16/09 non ce n'e' nessuno con i nomi;
        # se un giorno comparisse, la build si ferma qui e lo si sistema alla
        # fonte.
        errori.append("archivio %s con i nomi nei byte: riscriverlo lo romperebbe, "
                      "va sistemato alla fonte: %s" % (formato, percorso))
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
    archivi = 0
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
                    dati = f.read()
            except OSError as e:
                errori.append("illeggibile %s: %s" % (v, e))
                continue
            if formato_compresso(dati):
                archivi += 1
            r = menzioni_in_archivio(dati)
            if r is None:
                errori.append("archivio che non si sa aprire, quindi NON verificato: %s" % v)
            elif r[0]:
                trovati.append("nel contenuto (%s): %s" % (r[1], v))
            if PHAR.e_phar(dati) and PHAR.impronta_valida(dati) is not True:
                errori.append("PHAR con impronta interna non valida: %s" % v)
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
    print("  %d voci esaminate, %d archivi aperti e guardati dentro, nessuna menzione"
          % (esaminati, archivi))
    print("  (i PHAR si guardano sui byte: le loro voci compresse le legge PHP nel passo apposito)")
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
