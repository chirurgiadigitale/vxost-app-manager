#!/usr/bin/env python3
"""Apache ha letto DAVVERO questo file?

Legge l'uscita di `httpd -D DUMP_INCLUDES` e cerca il file atteso, passato in
VXATTESO. Esce 0 se c'e', 1 se no, 2 se non ha potuto guardare.

⚠️ Il confronto e' sui percorsi SCIOLTI, non sul testo. Il dump stampa il
percorso con cui il file e' stato raggiunto: un Include attraverso un
collegamento lecito stampa l'alias, e un confronto letterale lo respingeva.
E il confronto letterale serve comunque: cercando il percorso come modello,
il punto fra "vxost" e "conf" accetta qualunque carattere, quindi un file
"httpd-vxostXconf" passava per il nostro.
"""
import os
import re
import sys

# Le righe del dump sono "  (*) /percorso" oppure "  (12) /percorso".
RIGA = re.compile(r"^\s*\([^)]*\)\s+(/.*\S)\s*$")


def main():
    atteso = os.environ.get("VXATTESO")
    if not atteso or len(sys.argv) != 2:
        print("uso: VXATTESO=<file> incluso-davvero.py <dump>", file=sys.stderr)
        return 2
    try:
        righe = open(sys.argv[1], encoding="utf-8", errors="replace").read().split("\n")
    except OSError as errore:
        print("  non ho potuto leggere il dump: %s" % errore, file=sys.stderr)
        return 2
    try:
        vero = os.path.realpath(atteso)
    except OSError:
        return 2
    for riga in righe:
        trovata = RIGA.match(riga)
        if not trovata:
            continue
        try:
            if os.path.realpath(trovata.group(1)) == vero:
                return 0
        except OSError:
            continue
    return 1


if __name__ == "__main__":
    sys.exit(main())
