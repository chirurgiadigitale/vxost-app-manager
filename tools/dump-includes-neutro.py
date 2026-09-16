#!/usr/bin/env python3
"""La configurazione non deve condizionarsi a DUMP_INCLUDES.

Il dump degli Include si ottiene passando -D DUMP_INCLUDES, quindi una
configurazione che nomina QUEL define si comporta diversamente durante il
controllo e durante l'avvio. Il caso che fa danno e' <IfDefine !DUMP_INCLUDES>:
il file non compare nel dump e Apache lo legge lo stesso, cioe' sfugge alla
prova di isolamento.

⚠️ Prima questo controllo era un grep su una riga sola. Il nono giro ha
dimostrato quattro forme di sintassi valida che lo attraversavano, e una
regressione nella direzione opposta:

    <IFDEFINE DUMP_INCLUDES>          le direttive sono insensibili alle maiuscole
    <IfDefine "DUMP_INCLUDES">        l'argomento puo' essere fra virgolette
    <IfDefine \\                       e puo' stare sulla riga dopo
     DUMP_INCLUDES>
    Define PROBE DUMP_INCLUDES        e puo' arrivare da una variabile
    <IfDefine ${PROBE}>

    # <IfDefine DUMP_INCLUDES>        un COMMENTO faceva fallire la build

Qui si uniscono le continuazioni, si scartano i commenti, si toglie la
distinzione fra maiuscole SOLO dal nome della direttiva (i nomi dei define
sono sensibili, in Apache) e si seguono le variabili.
"""
import os
import re
import sys

BERSAGLIO = "DUMP_INCLUDES"


def righe_logiche(testo):
    """Le righe come Apache le vede: continuazioni unite, commenti fuori.

    ⚠️ In Apache il commento vale solo se il '#' apre la riga: a meta' riga e'
    un carattere qualunque. E la barra rovescia a fine riga continua, quindi
    una direttiva puo' essere spezzata dove capita.
    """
    unite = []
    accumulo = ""
    for riga in testo.splitlines():
        riga = riga.rstrip("\n")
        if accumulo:
            accumulo += " " + riga.strip()
        else:
            if riga.lstrip().startswith("#"):
                continue
            accumulo = riga.strip()
        if accumulo.endswith("\\"):
            accumulo = accumulo[:-1].rstrip()
            continue
        if accumulo:
            unite.append(accumulo)
        accumulo = ""
    if accumulo:
        unite.append(accumulo)
    return unite


def spoglia(arg):
    """Toglie le virgolette, che in Apache sono un modo di scrivere, non parte
    del nome."""
    arg = arg.strip()
    if len(arg) >= 2 and arg[0] == arg[-1] and arg[0] in "\"'":
        arg = arg[1:-1]
    return arg


def esamina(radice):
    alias = {BERSAGLIO}          # i nomi che valgono DUMP_INCLUDES
    usi = []                     # (file, riga) che ci si condizionano

    file_conf = []
    for base, _dirs, nomi in os.walk(radice, onerror=lambda e: file_conf.append(None)):
        for n in sorted(nomi):
            if n.endswith((".conf", ".inc")):
                file_conf.append(os.path.join(base, n))
    if None in file_conf:
        return None, "non ho potuto leggere una cartella sotto %s" % radice

    # Due passate: prima i Define, perche' un alias puo' essere dichiarato in
    # un file e usato in un altro.
    for _ in range(2):
        for f in file_conf:
            try:
                testo = open(f, encoding="utf-8", errors="replace").read()
            except OSError as e:
                return None, "non ho potuto leggere %s: %s" % (f, e)
            for riga in righe_logiche(testo):
                campi = riga.split(None, 2)
                if len(campi) >= 3 and campi[0].lower() == "define":
                    if spoglia(campi[2]) in alias:
                        alias.add(spoglia(campi[1]))

    for f in file_conf:
        testo = open(f, encoding="utf-8", errors="replace").read()
        for riga in righe_logiche(testo):
            m = re.match(r"<\s*ifdefine\s+(.*?)\s*>", riga, re.IGNORECASE)
            if not m:
                continue
            arg = spoglia(m.group(1)).lstrip("!").strip()
            nudo = arg
            v = re.fullmatch(r"\$\{(.+)\}", arg)
            if v:
                nudo = v.group(1)
            if nudo in alias:
                usi.append((f, riga))
    return usi, None


def main():
    if len(sys.argv) != 2:
        print("uso: dump-includes-neutro.py <cartella etc>", file=sys.stderr)
        return 2
    usi, errore = esamina(sys.argv[1])
    if errore:
        print("!! %s" % errore, file=sys.stderr)
        return 2
    if usi:
        print("!! la configurazione si condiziona a %s: da qui non si puo'"
              % BERSAGLIO, file=sys.stderr)
        print("   distinguere quello che Apache legge all'avvio da quello che",
              file=sys.stderr)
        print("   legge durante questo controllo", file=sys.stderr)
        for f, riga in usi:
            print("     %s: %s" % (f, riga), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
