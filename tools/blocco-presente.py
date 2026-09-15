#!/usr/bin/env python3
"""Un blocco di testo c'e' dentro un file, identico?

Stampa "identico", "diverso" (il marcatore c'e' ma il testo no) o "assente".

⚠️ Esiste come file a se' e non come heredoc dentro build-stack.sh perche' il
bash di macOS e' il 3.2: dentro $(cat <<EOF) conta gli apici anche quando
stanno nell'heredoc, e un numero dispari di apostrofi rompe lo script seicento
righe piu' in giu'.
"""
import sys

MARCATORE = "i diagnostici rispondono solo a questo Mac"


def main():
    if len(sys.argv) != 3:
        print("uso: blocco-presente.py <blocco> <file>", file=sys.stderr)
        return 2
    try:
        blocco = open(sys.argv[1], encoding="utf-8").read()
        testo = open(sys.argv[2], encoding="utf-8", errors="replace").read()
    except OSError as errore:
        print("assente")
        print("  %s" % errore, file=sys.stderr)
        return 0
    if blocco and blocco in testo:
        print("identico")
    elif MARCATORE in testo:
        print("diverso")
    else:
        print("assente")
    return 0


if __name__ == "__main__":
    sys.exit(main())
