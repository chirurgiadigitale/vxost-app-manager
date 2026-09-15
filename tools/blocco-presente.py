#!/usr/bin/env python3
"""Un blocco di testo c'e' dentro un file, identico?

Stampa "identico", "diverso" (il marcatore c'e' ma il testo no) o "assente".

⚠️ Esiste come file a se' e non come heredoc dentro build-stack.sh perche' il
bash di macOS e' il 3.2: dentro $(cat <<EOF) conta gli apici anche quando
stanno nell'heredoc, e un numero dispari di apostrofi rompe lo script seicento
righe piu' in giu'.
"""
import re
import sys

MARCATORE = "i diagnostici rispondono solo a questo Mac"

# I contenitori di Apache che possono racchiudere, e quindi disattivare o
# restringere, un blocco che si vuole sempre attivo.
CONTENITORI = ("ifdefine", "ifmodule", "ifversion", "if", "elseif", "else",
               "virtualhost", "directory", "directorymatch", "location",
               "locationmatch", "files", "filesmatch", "limit", "limitexcept",
               "proxy", "proxymatch", "macro")


def annidato(testo, posizione):
    """Vero se a quella posizione siamo dentro un contenitore aperto."""
    profondita = 0
    for riga in testo[:posizione].split("\n"):
        pulita = riga.strip()
        if not pulita or pulita.startswith("#"):
            continue
        aperto = re.match(r"^<([A-Za-z]+)", pulita)
        chiuso = re.match(r"^</([A-Za-z]+)", pulita)
        if chiuso and chiuso.group(1).lower() in CONTENITORI:
            profondita = max(0, profondita - 1)
        elif aperto and aperto.group(1).lower() in CONTENITORI:
            profondita += 1
    return profondita > 0


def riga_attiva(percorso, frammento):
    """La riga che contiene il frammento sta al livello esterno del file?

    ⚠️ Serve perche' un blocco puo' stare benissimo al livello esterno del
    SUO file, mentre quel file viene incluso da dentro un <IfDefine> mai
    vero. In quel caso Apache non lo legge, il confronto testuale dice
    "identico" e il configtest dice Syntax OK: il controllo dichiarava
    attiva una regola che non entra mai in gioco.
    """
    try:
        testo = open(percorso, encoding="utf-8", errors="replace").read()
    except OSError as errore:
        print("illeggibile", file=sys.stderr)
        print("  %s" % errore, file=sys.stderr)
        return 2
    posizione = testo.find(frammento)
    if posizione < 0:
        print("assente")
        return 1
    if testo.count(frammento) > 1:
        print("piu-volte")
        return 1
    print("annidato" if annidato(testo, posizione) else "attivo")
    return 0


def main():
    if len(sys.argv) == 4 and sys.argv[1] == "--riga":
        return riga_attiva(sys.argv[2], sys.argv[3])
    if len(sys.argv) != 3:
        print("uso: blocco-presente.py <blocco> <file>", file=sys.stderr)
        print("     blocco-presente.py --riga <file> <frammento>", file=sys.stderr)
        return 2
    try:
        blocco = open(sys.argv[1], encoding="utf-8").read()
        testo = open(sys.argv[2], encoding="utf-8", errors="replace").read()
    except OSError as errore:
        print("assente")
        print("  %s" % errore, file=sys.stderr)
        return 0
    if not blocco:
        print("assente")
        return 0

    quante = testo.count(blocco)
    if quante == 0:
        print("diverso" if MARCATORE in testo else "assente")
        return 0
    if quante > 1:
        # Due copie: non si sa quale conti, e una potrebbe essere disattivata.
        print("diverso")
        return 0

    # ⚠️ Esserci non vuol dire essere ATTIVO. Racchiudendo il blocco esatto in
    # un <IfDefine MAI_DEFINITO>, il confronto diceva "identico", Apache diceva
    # Syntax OK e il diagnostico rispondeva 200. Un blocco che nomina
    # <Directory> deve stare al livello piu' esterno del file: qui si contano
    # i contenitori aperti prima di lui.
    if annidato(testo, testo.index(blocco)):
        print("diverso")
        return 0

    print("identico")
    return 0


if __name__ == "__main__":
    sys.exit(main())
