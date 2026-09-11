#!/usr/bin/env python3
"""L'impronta di uno staging: ogni file, con il suo contenuto.

Serve a legare il disco confezionato allo staging che ha superato i controlli
di build-stack.sh. Prima quel legame era la data del timbro, con
`find -newer`, e una data non e' un contenuto:

    1. si crea un file
    2. si scrive il timbro
    3. si cambia il contenuto del file
    4. si rimette la data di prima con touch -t
    5. `find -newer` non trova niente, e il DMG esce con il file cambiato

Qui si legge quello che c'e' dentro. Il manifesto elenca, in ordine:

    f <sha256> <byte> <permessi> <percorso>
    l <bersaglio> <percorso>
    d <permessi> <percorso>

I permessi ci sono perche' un file eseguibile che smette di esserlo rompe il
pacchetto senza cambiare un byte di contenuto. I bersagli dei link ci sono
perche' cambiare dove punta un link non cambia nessun file.

Uso:
    python3 tools/stage-manifest.py <staging>            > manifesto
    python3 tools/stage-manifest.py <staging> --confronta <manifesto>

Nella seconda forma stampa le differenze ed esce 1 se ce ne sono: e' quello
che fa build-stack-dmg.sh prima di confezionare.
"""
import hashlib
import os
import sys

# Le due cose che finiscono nel disco. Il resto della cartella di staging (il
# timbro, il manifesto stesso, gli appunti) non viene confezionato e quindi
# non fa parte dell'impronta.
CONTENUTO = ("vxostfiles", "VXOST.app")

BLOCCO = 1024 * 1024


def impronta(percorso):
    """Lo sha256 di un file, letto a blocchi: nel pacchetto c'e' anche roba
    da centinaia di megabyte, e leggerla tutta in memoria non serve."""
    h = hashlib.sha256()
    with open(percorso, "rb") as f:
        while True:
            pezzo = f.read(BLOCCO)
            if not pezzo:
                break
            h.update(pezzo)
    return h.hexdigest()


def manifesto(staging):
    """Le righe del manifesto, ordinate per percorso.

    ⚠️ L'ordine e' dato da sorted() e non da quello che restituisce il
    filesystem: due esecuzioni sulla stessa cartella devono produrre lo stesso
    testo, altrimenti il confronto fallisce senza che sia cambiato niente.
    """
    righe = []
    problemi = []
    for radice in CONTENUTO:
        base = os.path.join(staging, radice)
        if not os.path.exists(base):
            problemi.append("manca " + radice)
            continue
        for cartella, sottocartelle, nomi in os.walk(base, followlinks=False):
            sottocartelle.sort()
            for nome in sorted(sottocartelle + nomi):
                intero = os.path.join(cartella, nome)
                relativo = os.path.relpath(intero, staging)
                try:
                    st = os.lstat(intero)
                    modo = oct(st.st_mode & 0o7777)[2:].rjust(4, "0")
                    if os.path.islink(intero):
                        righe.append("l %s %s" % (os.readlink(intero), relativo))
                    elif os.path.isdir(intero):
                        righe.append("d %s %s" % (modo, relativo))
                    else:
                        righe.append("f %s %d %s %s"
                                     % (impronta(intero), st.st_size, modo, relativo))
                except OSError as errore:
                    # Un file che non si riesce a leggere non e' un file
                    # verificato: non si salta in silenzio.
                    problemi.append("%s: %s" % (relativo, errore))
    return sorted(righe), problemi


def main():
    if len(sys.argv) < 2:
        print("uso: stage-manifest.py <staging> [--confronta <manifesto>]",
              file=sys.stderr)
        return 2
    staging = sys.argv[1]
    if not os.path.isdir(staging):
        print("  %s non e' una cartella" % staging, file=sys.stderr)
        return 2

    righe, problemi = manifesto(staging)
    if problemi:
        for p in problemi:
            print("  " + p, file=sys.stderr)
        print("  lo staging non e' leggibile per intero", file=sys.stderr)
        return 2

    if len(sys.argv) == 2:
        sys.stdout.write("\n".join(righe) + "\n")
        return 0

    if sys.argv[2] != "--confronta" or len(sys.argv) < 4:
        print("uso: stage-manifest.py <staging> [--confronta <manifesto>]",
              file=sys.stderr)
        return 2

    with open(sys.argv[3], encoding="utf-8") as f:
        attese = f.read().split("\n")
    attese = [r for r in attese if r]

    # Il confronto dice COSA e' cambiato, non solo che qualcosa lo e': con
    # novantamila righe, "il manifesto non combacia" non aiuta nessuno.
    def per_percorso(elenco):
        mappa = {}
        for riga in elenco:
            pezzi = riga.split(" ")
            mappa[pezzi[-1]] = riga
        return mappa

    prima, adesso = per_percorso(attese), per_percorso(righe)
    aggiunti = sorted(set(adesso) - set(prima))
    tolti = sorted(set(prima) - set(adesso))
    cambiati = sorted(p for p in set(prima) & set(adesso) if prima[p] != adesso[p])

    if not (aggiunti or tolti or cambiati):
        return 0

    for elenco, etichetta in ((tolti, "tolto"), (aggiunti, "aggiunto"),
                              (cambiati, "cambiato")):
        for percorso in elenco[:10]:
            print("  %-9s %s" % (etichetta, percorso), file=sys.stderr)
        if len(elenco) > 10:
            print("  %-9s e altri %d" % ("", len(elenco) - 10), file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
