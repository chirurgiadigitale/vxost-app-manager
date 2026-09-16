#!/usr/bin/env python3
"""Le impronte interne degli archivi PHAR.

Un PHAR finisce con: impronta, 4 byte col tipo, "GBMB". L'impronta copre tutto
quello che la precede. Cambiare anche un solo byte, a parita' di lunghezza, la
rende falsa e PHP rifiuta l'archivio intero.

    phar-impronte.py ripara <cartella>...   ricalcola le impronte che non tornano

⚠️ Perche' esiste. bin/phar.phar del pacchetto non partiva: "SHA1 signature
could not be verified". La rinomina del 13/08 aveva riscritto l'intestazione
non compressa senza ricalcolare l'impronta. Il dodicesimo giro di Codex l'ha
trovato; il file era identico nella sorgente, quindi rotto da prima.

⚠️ Ricalcolare un'impronta NON prova che il contenuto sia sano: la rende solo
coerente con i byte che ci sono. La prova vera e' leggere ogni voce con PHP,
che controlla il CRC di ciascuna, ed e' il passo "Checking the PHAR archives"
della build, subito dopo. Senza quel passo questo strumento nasconderebbe un
danno invece di ripararlo.

Solo impronte a hash (MD5, SHA-1, SHA-256, SHA-512). Una firma OpenSSL non si
ricalcola senza la chiave privata: lo script si ferma.
"""
import hashlib
import os
import struct
import sys

HASH = {1: hashlib.md5, 2: hashlib.sha1, 3: hashlib.sha256, 4: hashlib.sha512}


def e_phar(dati):
    return len(dati) > 12 and dati.endswith(b"GBMB") and b"__HALT_COMPILER();" in dati


def impronta_valida(dati):
    """True, False, o None se il tipo non e' un hash noto."""
    tipo = struct.unpack("<I", dati[-8:-4])[0]
    h = HASH.get(tipo)
    if not h:
        return None
    n = h().digest_size
    return dati[-(n + 8):-8] == h(dati[:-(n + 8)]).digest()


def firma(dati):
    """I byte con l'impronta ricalcolata, o None se il tipo non e' un hash."""
    tipo = struct.unpack("<I", dati[-8:-4])[0]
    h = HASH.get(tipo)
    if not h:
        return None
    n = h().digest_size
    corpo = dati[:-(n + 8)]
    return corpo + h(corpo).digest() + dati[-8:]


def scrivi_sul_posto(percorso, dati):
    modo = os.stat(percorso).st_mode
    if not modo & 0o200:
        os.chmod(percorso, modo | 0o200)
    try:
        with open(percorso, "r+b") as f:
            f.write(dati)
    finally:
        os.chmod(percorso, modo)


def ripara(radici):
    errori, riparati, sani = [], 0, 0
    for radice in radici:
        for base, _, file in os.walk(radice, onerror=lambda e: errori.append(str(e))):
            for n in file:
                p = os.path.join(base, n)
                if os.path.islink(p):
                    continue
                try:
                    with open(p, "rb") as f:
                        dati = f.read()
                except OSError as e:
                    errori.append("illeggibile %s: %s" % (p, e))
                    continue
                if not e_phar(dati):
                    continue
                valida = impronta_valida(dati)
                if valida is None:
                    errori.append("firma non a hash, non ricalcolabile: %s" % p)
                elif valida:
                    sani += 1
                else:
                    scrivi_sul_posto(p, firma(dati))
                    riparati += 1
                    print("  impronta ricalcolata: %s" % os.path.relpath(p, radice))
    for e in errori:
        print("!! %s" % e, file=sys.stderr)
    print("  %d PHAR con l'impronta gia' giusta, %d ricalcolate" % (sani, riparati))
    return 1 if errori else 0


def elenca(radici):
    """I PHAR riconosciuti dal formato, non dall'estensione, uno per riga."""
    for radice in radici:
        for base, _, file in os.walk(radice):
            for n in file:
                p = os.path.join(base, n)
                if os.path.islink(p):
                    continue
                try:
                    with open(p, "rb") as f:
                        if e_phar(f.read()):
                            print(p)
                except OSError:
                    print("!! illeggibile %s" % p, file=sys.stderr)
                    return 1
    return 0


if __name__ == "__main__":
    modi = {"ripara": ripara, "elenca": elenca}
    if len(sys.argv) < 3 or sys.argv[1] not in modi:
        print(__doc__.split("\n\n")[2], file=sys.stderr)
        sys.exit(2)
    sys.exit(modi[sys.argv[1]](sys.argv[2:]))
