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

Percorsi e bersagli sono CITATI: spazi, a capo, tabulazioni e barre rovesce
diventano \\s \\n \\t \\\\. Senza, due cose andavano storte insieme: le righe non
si sapevano piu' dividere in campi (nel pacchetto ci sono sette file con uno
spazio nel nome), e il confronto usava l'ultima parola della riga come chiave,
quindi due percorsi che finiscono uguale si sovrascrivevano e uno dei due
spariva dal confronto senza che niente lo dicesse.

Non sono rappresentati, e vanno detti invece di lasciarli intendere: la
topologia degli hard link, il proprietario, le ACL e gli attributi estesi. Due
file identici al posto di un hard link danno lo stesso pacchetto a chi
installa; il proprietario viene rifatto dall'installazione. Il manifesto lega
CONTENUTO, PERMESSI e BERSAGLI DEI LINK, e non promette altro.

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
import stat
import sys

# Le due cose che finiscono nel disco. Il resto della cartella di staging (il
# timbro, il manifesto stesso, gli appunti) non viene confezionato e quindi
# non fa parte dell'impronta.
CONTENUTO = ("vxostfiles", "VXOST.app")

BLOCCO = 1024 * 1024

# Il numero di formato sta nella prima riga. Cambiandolo, un manifesto vecchio
# viene riconosciuto come tale e lo si dice: senza, il confronto sputerebbe
# ventisettemila differenze e nessuno capirebbe che e' solo un altro formato.
INTESTAZIONE = "#manifesto 2"

CITAZIONI = ((chr(92), chr(92) + chr(92)), (" ", chr(92) + "s"),
             ("\n", chr(92) + "n"), ("\r", chr(92) + "r"), ("\t", chr(92) + "t"))


def cita(testo):
    """Un percorso o un bersaglio come UN campo, senza spazi ne' a capo."""
    for carattere, sostituto in CITAZIONI:
        testo = testo.replace(carattere, sostituto)
    return testo


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

    def guasto(errore):
        # ⚠️ os.walk senza questo INGOIA gli errori di discesa: una cartella
        # illeggibile spariva insieme a tutto quello che conteneva, e il
        # manifesto usciva completo di quello che era riuscito a leggere.
        problemi.append("%s: %s" % (getattr(errore, "filename", "?"), errore))

    def registra(intero, relativo):
        st = os.lstat(intero)
        modo = oct(st.st_mode & 0o7777)[2:].rjust(4, "0")
        if stat.S_ISLNK(st.st_mode):
            righe.append("l %s %s" % (cita(os.readlink(intero)), cita(relativo)))
        elif stat.S_ISDIR(st.st_mode):
            righe.append("d %s %s" % (modo, cita(relativo)))
        elif stat.S_ISREG(st.st_mode):
            righe.append("f %s %d %s %s"
                         % (impronta(intero), st.st_size, modo, cita(relativo)))
        else:
            # ⚠️ Fifo, socket e device non si impronta: aprire una fifo in
            # lettura resta in attesa di uno scrittore che non arrivera' mai,
            # e la build si ferma li' senza dire perche'. E comunque in un
            # pacchetto non ci vanno.
            problemi.append("%s: non e' un file, un link o una cartella" % relativo)

    for radice in CONTENUTO:
        base = os.path.join(staging, radice)
        # ⚠️ La radice stessa va registrata. Prima bastava che esistesse:
        # cambiandone i permessi il confronto passava, e sostituendo VXOST.app
        # con un file ordinario os.walk non produceva niente e la generazione
        # usciva 0 su uno staging senza l'applicazione.
        if not os.path.isdir(base):
            problemi.append("manca %s, o non e' una cartella" % radice)
            continue
        try:
            registra(base, radice)
        except OSError as errore:
            problemi.append("%s: %s" % (radice, errore))
            continue
        for cartella, sottocartelle, nomi in os.walk(base, followlinks=False,
                                                     onerror=guasto):
            sottocartelle.sort()
            for nome in sorted(sottocartelle + nomi):
                intero = os.path.join(cartella, nome)
                relativo = os.path.relpath(intero, staging)
                try:
                    registra(intero, relativo)
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
        sys.stdout.write("\n".join([INTESTAZIONE] + righe) + "\n")
        return 0

    if sys.argv[2] != "--confronta" or len(sys.argv) < 4:
        print("uso: stage-manifest.py <staging> [--confronta <manifesto>]",
              file=sys.stderr)
        return 2

    with open(sys.argv[3], encoding="utf-8") as f:
        attese = f.read().split("\n")
    attese = [r for r in attese if r]

    # ⚠️ Un manifesto di un altro formato non e' uno staging cambiato, e dirlo
    # in questo modo evita di leggere ventisettemila differenze per capirlo.
    # Il timbro va rifatto RICOSTRUENDO lo staging, non ricalcolando l'hash
    # sopra quello che c'e'.
    if not attese or attese[0] != INTESTAZIONE:
        print("  il manifesto e' di un altro formato (atteso %r)" % INTESTAZIONE,
              file=sys.stderr)
        print("  ricostruire lo staging, non rigenerare il timbro",
              file=sys.stderr)
        return 2
    attese = attese[1:]

    # Il confronto dice COSA e' cambiato, non solo che qualcosa lo e': con
    # novantamila righe, "il manifesto non combacia" non aiuta nessuno.
    def per_percorso(elenco):
        mappa = {}
        for riga in elenco:
            # Il percorso e' l'ultimo campo ed e' citato, quindi non contiene
            # spazi: la chiave e' il percorso intero, non la sua ultima parola.
            # ⚠️ Prima era pezzi[-1] su un percorso NON citato, cioe' l'ultima
            # parola: due percorsi che finivano uguale si sovrascrivevano, e
            # quello nascosto poteva cambiare senza che il confronto lo dicesse.
            chiave = riga.rsplit(" ", 1)[-1]
            if chiave in mappa:
                # Non puo' succedere con i percorsi citati, e se succede il
                # confronto non e' affidabile: meglio fermarsi.
                raise SystemExit("  due righe per lo stesso percorso: " + chiave)
            mappa[chiave] = riga
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
