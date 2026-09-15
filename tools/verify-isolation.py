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

⚠️ E si distingue quello che rompiamo noi da quello che ereditiamo. Lo stack
   upstream e' pieno di dipendenze verso macchine che non esistono piu':
   /ade/b/2649109290/... e' la macchina di build di Oracle, /bitnami/... quella
   di chi ha compilato XAMPP, e postgresql/lib/libpq.5.dylib non c'e' nemmeno
   nell'installazione da cui copiamo. Sono cosi' da prima di noi e non si
   correggono senza ricompilare: farci fallire la build vuol dire non
   costruire mai piu'. Si elencano, e si ferma la build solo per le
   dipendenze che la SORGENTE aveva e il pacchetto no, cioe' quelle che il
   confezionamento ha perso per strada.

Uso:
    python3 tools/verify-isolation.py <specchio> <payload> <radice-installazione> [<sorgente>]

Esce 0 se non ci sono problemi, 1 se ce ne sono, 2 se non ha potuto guardare.
"""
import glob
import os
import re
import shlex
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
    "sslpassphrasedialog": 1, "sslcryptodevice": 1, "sslstaplingcache": 1,
    "authdbmuserfile": 1, "authdbmgroupfile": 1, "rewritemap": 2,
    "mutex": 0,  # "Mutex default:/percorso": l'argomento va spacchettato
}

# Direttive che accettano PIU' percorsi, non uno. ⚠️ LoadFile ne prende quanti
# gliene dai: guardando solo il primo, "LoadFile interno.dylib
# /opt/homebrew/fuori.dylib" passava senza che il secondo venisse mai visto.
MULTI_ARGOMENTI = ("loadfile",)

# I -D con cui Apache viene davvero avviato: dentro questi blocchi le
# direttive contano, quindi l'esistenza si pretende. ⚠️ Prima QUALUNQUE
# <IfDefine> sopprimeva il controllo, anche <IfDefine SSL>, che e' attivo.
DEFINE_ATTIVI = ("ssl", "php")

# Cosa puo' stare FUORI dal pacchetto, DIRETTIVA PER DIRETTIVA.
#
# ⚠️ Un elenco unico di prefissi ignora il ruolo della direttiva, e sbagliava
# in tutti e due i sensi: /etc va bene per mime.types e non per un
# DocumentRoot, e /Library/Frameworks non e' roba di Apple, e' roba installata
# da qualcuno. Un modulo caricato da li' passava il controllo.
#
# Le direttive che non compaiono qui non possono nominare niente fuori dal
# pacchetto: DocumentRoot, Alias, Include, i certificati, i file di password.
FUORI_AMMESSO = {
    "typesconfig": ("/etc/", "/usr/share/"),
    "mimemagicfile": ("/etc/", "/usr/share/"),
    "sslrandomseed": ("/dev/",),
    "mutex": ("/var/run/", "/private/var/run/", "/tmp/", "/private/tmp/"),
    "defaultruntimedir": ("/var/run/", "/private/var/run/"),
    "pidfile": ("/var/run/", "/private/var/run/"),
    "loadmodule": ("/usr/lib/", "/System/"),
    "loadfile": ("/usr/lib/", "/System/"),
    "errorlog": ("/var/log/", "/private/var/log/", "/dev/"),
    "customlog": ("/var/log/", "/private/var/log/", "/dev/"),
    "transferlog": ("/var/log/", "/private/var/log/", "/dev/"),
}

# Le direttive il cui bersaglio deve ESISTERE. Un modulo che non c'e' non e'
# un modulo isolato, e' un avvio che fallisce. Gli Include con un glob restano
# fuori: un glob che non trova niente e' lecito.
DEVE_ESISTERE = ("loadmodule", "loadfile", "include", "typesconfig",
                 "sslcertificatefile", "sslcertificatekeyfile")

# Solo le librerie di sistema vere. ⚠️ /Library/Frameworks NON e' qui: le
# librerie di Apple stanno in /System/Library/Frameworks, e /Library/Frameworks
# e' dove installa il software di terze parti.
SISTEMA_LIB = ("/usr/lib/", "/System/")

MAGIE = (0xfeedface, 0xfeedfacf, 0xcefaedfe, 0xcffaedfe, 0xcafebabe, 0xbebafeca)


def e_mach_o(percorso):
    """⚠️ CA FE BA BE non basta: e' la firma dei binari universali Mach-O E
    quella dei .class di Java. share/gettext/javaversion.class ha fatto
    fallire la build dicendo che otool non rispondeva, il 11/09/2026.

    Dopo la firma, un .class porta la versione del formato (>= 45 per Java 1.0)
    dove un binario universale porta il numero di architetture, che e' un
    numero piccolo: nessuno spedisce un binario per 45 architetture."""
    try:
        with open(percorso, "rb") as f:
            testa = f.read(8)
    except OSError:
        return False
    if len(testa) < 4:
        return False
    magia = struct.unpack(">I", testa[:4])[0]
    if magia not in MAGIE:
        return False
    if magia in (0xcafebabe, 0xbebafeca) and len(testa) == 8:
        quante = struct.unpack(">I", testa[4:8])[0]
        if quante > 30:
            return False          # e' un .class di Java, non un fat binary
    return True


def dentro(percorso, *basi):
    """Vero se percorso sta dentro una delle basi, guardando dove i link
    portano DAVVERO.

    ⚠️ Il confronto testuale bastava per dire di si': <specchio>/../fuori
    comincia per <specchio>/ e passava, e cosi' un DocumentRoot dentro una
    cartella dello specchio che e' un link a un'altra parte del disco.

    ⚠️ Le basi sono piu' d'una perche' lo specchio E' fatto di link verso il
    payload: build-stack.sh ci mette un link per ogni voce tranne etc/, che
    copia. Sciogliendo i link, ogni modulo risulta "fuori dallo specchio" pur
    essendo esattamente dentro il pacchetto. I link VOLUTI si ammettono
    nominando l'altra base, non allentando il confronto.
    """
    try:
        vero = os.path.realpath(percorso)
    except OSError:
        return False
    for base in basi:
        if not base:
            continue
        try:
            b = os.path.realpath(base)
        except OSError:
            continue
        if vero == b or vero.startswith(b + os.sep):
            return True
    return False


def argomenti(riga):
    """I pezzi di una riga di configurazione, virgolette comprese.

    ⚠️ split() spezzava "modulo con spazio.so" al primo spazio e ne guardava
    la prima meta': un percorso mai esistito passava per buono.
    """
    try:
        return shlex.split(riga, comments=False)
    except ValueError:
        return None


def percorsi_nell_argomento(pezzo):
    """I percorsi nascosti dentro UN argomento.

    ⚠️ Un percorso non sta sempre da solo. Apache lo infila dentro:

        SSLSessionCache      shmcb:/percorso(512000)
        SSLPassPhraseDialog  exec:/percorso
        CustomLog            "|/percorso/programma"

    Guardando l'argomento intero e chiedendo che cominci per "/", tutti e tre
    sparivano e il controllo diceva "0 fuori" su una configurazione che
    caricava roba da /opt/homebrew.
    """
    trovati = []
    if not pezzo:
        return trovati
    # Un programma dietro una pipe e' un eseguibile da cui si dipende, non
    # una cosa da saltare.
    if pezzo.startswith("|"):
        pezzo = pezzo[1:].strip()
        if pezzo:
            trovati.append(pezzo.split()[0])
        return trovati
    if pezzo.startswith("/"):
        trovati.append(pezzo)
        return trovati
    # meccanismo:/percorso, con eventuali parametri fra parentesi in coda
    if ":" in pezzo:
        coda = pezzo.split(":", 1)[1]
        coda = re.sub(r"\(.*\)$", "", coda)
        if coda.startswith("/"):
            trovati.append(coda)
            return trovati
    # ⚠️ Tutto il resto torna com'e': sono i percorsi RELATIVI a ServerRoot,
    # che chi chiama risolve. Scartandoli, i percorsi esaminati sullo staging
    # vero sono passati da 180 a 38 e il controllo usciva 0 lo stesso, cioe'
    # diceva "nessuno fuori" dopo aver guardato un quinto della configurazione.
    trovati.append(pezzo)
    return trovati


def percorsi_nella_configurazione(specchio):
    """Ogni percorso nominato da una direttiva attiva, con la riga.

    Legge i file per estensione E SEGUE gli Include, glob compresi: un file
    incluso con un'estensione qualsiasi veniva saltato, e con lui tutto quello
    che caricava. Restituisce
    (file, numero, direttiva, percorso_assoluto, grezzo, errore).
    """
    trovati = []
    etc = os.path.join(specchio, "etc")

    # La radice per i percorsi relativi. Apache li risolve rispetto a
    # ServerRoot, e non guardarla voleva dire scartare in silenzio ogni
    # ../../fuori.conf, che e' il modo piu' semplice di uscire dal pacchetto.
    serverroot = specchio

    # ⚠️ Due insiemi diversi. ATTIVO e' quello che Apache legge davvero,
    # partendo da httpd.conf e seguendo gli Include: solo li' ha senso
    # pretendere che un modulo o un certificato ESISTA. Tutto il resto viene
    # letto lo stesso, perche' un percorso che porta fuori dal pacchetto e'
    # un problema anche in un file mai incluso, ma non se ne pretende
    # l'esistenza: etc/original/ e' la copia di sicurezza delle
    # configurazioni di partenza, e i suoi certificati non esistono e non
    # devono esistere.
    principale = os.path.join(etc, "httpd.conf")
    da_leggere = [principale] if os.path.exists(principale) else []
    attivi = set(os.path.realpath(f) for f in da_leggere)
    altri = []
    for cartella, _, nomi in os.walk(etc):
        for nome in sorted(nomi):
            if nome.endswith((".conf", ".ini")):
                intero = os.path.join(cartella, nome)
                if os.path.realpath(intero) not in attivi:
                    altri.append(intero)

    visti = set()
    while da_leggere or altri:
        if da_leggere:
            intero = da_leggere.pop(0)
            attivo = True
        else:
            intero = altri.pop(0)
            attivo = False
        vero = os.path.realpath(intero)
        if vero in visti:
            continue
        visti.add(vero)
        try:
            testo = open(intero, encoding="utf-8", errors="replace").read()
        except OSError as errore:
            trovati.append((intero, 0, None, None, None, str(errore), False, True))
            continue

        # ⚠️ Apache continua una direttiva sulla riga dopo con una barra
        # rovescia finale. Lasciandole spezzate, shlex si ferma sulla barra e
        # una CustomLog perfettamente valida diventava "riga non
        # interpretabile".
        grezze = testo.split("\n")
        righe = []
        accumulata = ""
        inizio = 1
        for indice, riga in enumerate(grezze, 1):
            if not accumulata:
                inizio = indice
            if riga.rstrip().endswith(chr(92)):
                accumulata += riga.rstrip()[:-1] + " "
                continue
            righe.append((inizio, accumulata + riga))
            accumulata = ""
        if accumulata:
            righe.append((inizio, accumulata))

        condizionale = 0
        profondita_ignota = []
        for numero, riga in righe:
            pulita = riga.strip()
            # ⚠️ Il punto e virgola: php.ini commenta cosi', e leggendo quelle
            # righe come direttive uscivano sessanta "riga non interpretabile"
            # su frasi in inglese piene di apostrofi.
            if not pulita or pulita.startswith(("#", ";")):
                continue

            # ⚠️ <IfDefine JUSTTOMAKEAPXSHAPPY> e' il modo in cui XAMPP tiene
            # buono apxs: dentro ci sono LoadModule di libphp4 e libphp5, che
            # non esistono e non si caricano mai. Pretendere che il file ci
            # sia li' dentro e' un falso allarme; che il percorso resti dentro
            # il pacchetto va preteso comunque.
            minuscola = pulita.lower()
            if minuscola.startswith(("<ifdefine", "<ifmodule", "<ifversion")):
                # ⚠️ <IfDefine SSL> non e' una condizione ignota: e' uno dei
                # -D con cui Apache parte davvero, quindi li' dentro le
                # direttive contano e l'esistenza si pretende. Prima
                # qualunque blocco condizionale sopprimeva il controllo, e un
                # certificato mancante sotto <IfDefine SSL> passava.
                nome_def = re.sub(r"^<if\w+\s+!?", "", minuscola).rstrip(">").strip()
                if not (minuscola.startswith("<ifdefine")
                        and nome_def in DEFINE_ATTIVI):
                    condizionale += 1
                    profondita_ignota.append(numero)
                continue
            if minuscola.startswith(("</ifdefine", "</ifmodule", "</ifversion")):
                if profondita_ignota:
                    profondita_ignota.pop()
                    condizionale = max(0, condizionale - 1)
                continue

            # Prima si guarda la prima parola: shlex si scomoda solo per una
            # direttiva che ci interessa, e le righe di prosa non lo fanno
            # nemmeno inciampare.
            primo = pulita.split(None, 1)[0].strip('"').lower()
            if primo not in DIRETTIVE:
                continue
            pezzi = argomenti(pulita)
            if pezzi is None:
                trovati.append((intero, numero, primo, None, pulita,
                                "riga non interpretabile", False, attivo))
                continue
            if not pezzi:
                continue
            direttiva = pezzi[0].lower()
            if direttiva == "serverroot" and len(pezzi) > 1:
                serverroot = pezzi[1] if pezzi[1].startswith("/") \
                    else os.path.join(specchio, pezzi[1])
            quale = DIRETTIVE.get(direttiva)
            if quale is None:
                continue

            grezzi = []
            if quale == 0 or direttiva in MULTI_ARGOMENTI:
                # Mutex e LoadFile: si guardano TUTTI gli argomenti.
                for pezzo in pezzi[1:]:
                    grezzi.extend(percorsi_nell_argomento(pezzo))
            elif len(pezzi) > quale:
                grezzi.extend(percorsi_nell_argomento(pezzi[quale]))

            for grezzo in grezzi:
                if not grezzo or grezzo.startswith("|"):
                    continue                    # un programma, non un file
                if "${" in grezzo or "%" in grezzo:
                    # Una variabile che qui non si sa espandere: si dice, non
                    # si scarta.
                    trovati.append((intero, numero, direttiva, None, grezzo,
                                    "contiene una variabile non espandibile",
                                    condizionale > 0, attivo))
                    continue
                # ⚠️ normpath anche sugli assoluti: /usr/lib/../../opt/homebrew
                # comincia per /usr/lib/, che e' un prefisso ammesso, e
                # passava il controllo prima di essere normalizzato.
                assoluto = os.path.normpath(grezzo) if grezzo.startswith("/") \
                    else os.path.normpath(os.path.join(serverroot, grezzo))
                trovati.append((intero, numero, direttiva, assoluto, grezzo, None,
                                condizionale > 0, attivo))

                if direttiva == "include" and any(c in grezzo for c in "*?["):
                    # ⚠️ Include con un glob che non trova niente FERMA Apache
                    # all'avvio: solo IncludeOptional lo consente. Il commento
                    # diceva "un glob vuoto e' lecito" confondendo le due
                    # direttive, e il caso passava.
                    if not glob.glob(assoluto):
                        trovati.append((intero, numero, direttiva, None, grezzo,
                                        "Include con un glob che non trova nessun file",
                                        condizionale > 0, attivo))
                if attivo and direttiva in ("include", "includeoptional"):
                    # ⚠️ Il contenuto degli inclusi va letto: un .inc che
                    # carica un modulo da /opt/homebrew non veniva mai aperto.
                    for incluso in sorted(glob.glob(assoluto)):
                        if os.path.isdir(incluso):
                            for c, _, n in os.walk(incluso):
                                for x in sorted(n):
                                    da_leggere.append(os.path.join(c, x))
                                    attivi.add(os.path.realpath(os.path.join(c, x)))
                        elif os.path.isfile(incluso):
                            da_leggere.append(incluso)
                            attivi.add(os.path.realpath(incluso))
    return trovati


def dipendenze(percorso):
    """Le librerie che un Mach-O si porta scritte dentro, @ compresi.

    ⚠️ I prefissi @rpath, @loader_path e @executable_path venivano saltati
    dicendo che "per costruzione non escono dal pacchetto". Non e' vero:
    @loader_path/../../fuori.dylib ne esce, e un @rpath puo' risolvere in una
    cartella esterna o non risolvere affatto. Qui si restituiscono tutti, e
    chi chiama li risolve.
    """
    try:
        uscita = subprocess.run(["otool", "-L", percorso], capture_output=True,
                                text=True, timeout=30)
    except (OSError, subprocess.SubprocessError) as errore:
        return None, str(errore)
    if uscita.returncode != 0:
        return None, (uscita.stderr or "otool ha risposto %d" % uscita.returncode).strip()
    nomi = []
    for riga in uscita.stdout.split("\n")[1:]:
        riga = riga.strip()
        if not riga:
            continue
        nomi.append(riga.split(" (compatibility")[0].strip())
    return nomi, None


def elenco_rpath(percorso):
    """Le LC_RPATH di un Mach-O, che sono quelle che @rpath usa."""
    try:
        uscita = subprocess.run(["otool", "-l", percorso], capture_output=True,
                                text=True, timeout=60)
    except (OSError, subprocess.SubprocessError):
        return None
    if uscita.returncode != 0:
        return None
    righe = uscita.stdout.split("\n")
    trovati = []
    for i, riga in enumerate(righe):
        if riga.strip() != "cmd LC_RPATH":
            continue
        for successiva in righe[i + 1:i + 5]:
            trovata = re.search(r"\bpath (.+?) \(offset \d+\)", successiva)
            if trovata:
                trovati.append(trovata.group(1))
                break
    return trovati


def candidati(lib, binario, eseguibile):
    """Dove puo' finire una dipendenza con un prefisso @.

    Ritorna (elenco, None) oppure (None, motivo) quando non si sa risolverla.
    """
    cartella = os.path.dirname(binario)
    if lib.startswith("@loader_path"):
        return [os.path.normpath(lib.replace("@loader_path", cartella, 1))], None
    if lib.startswith("@executable_path"):
        if not eseguibile:
            # In una libreria dipende da CHI la carica, e da qui non si sa.
            return None, "@executable_path in una libreria: dipende dal programma che la carica"
        return [os.path.normpath(lib.replace("@executable_path", cartella, 1))], None
    if lib.startswith("@rpath"):
        percorsi = elenco_rpath(binario)
        if percorsi is None:
            return None, "otool -l non ha risposto"
        if not percorsi:
            return None, "@rpath senza nessuna LC_RPATH: non risolve"
        risolti = []
        for base in percorsi:
            if base.startswith("@loader_path"):
                base = base.replace("@loader_path", cartella, 1)
            elif base.startswith("@executable_path"):
                if not eseguibile:
                    return None, "@rpath basato su @executable_path in una libreria"
                base = base.replace("@executable_path", cartella, 1)
            risolti.append(os.path.normpath(os.path.join(base, lib[len("@rpath/"):])))
        return risolti, None
    return [lib], None


def normalizza(percorso, radici):
    """Il percorso con la radice riportata a una forma sola.

    ⚠️ Prima si confrontavano gli ultimi tre pezzi del percorso, e tre pezzi
    uguali non vogliono dire stesso percorso: /review-a/team/lib/manca.dylib e
    /review-b/team/lib/manca.dylib finivano per essere "la stessa dipendenza"
    e una libreria mai vista veniva dichiarata ereditata. Si normalizzano solo
    le riscritture CHE SAPPIAMO essere state fatte, e per il resto si
    confronta alla lettera.
    """
    for vecchia in radici:
        if vecchia and percorso.startswith(vecchia + "/"):
            return "<radice>/" + percorso[len(vecchia) + 1:]
    return percorso


def dipendenza_gia_nella_sorgente(sorgente, relativo, lib, radici):
    """Vero se lo STESSO binario, nella sorgente, aveva gia' questa dipendenza.

    ⚠️ Senza questo confronto, ogni percorso che non esiste da nessuna parte
    veniva etichettato "rotto gia' nella sorgente, ereditato da upstream",
    compreso uno appena introdotto da un errore delle nostre patch. Nella
    riproduzione esterna una dipendenza inventata ha ottenuto quell'etichetta
    e il controllo e' uscito 0.
    """
    if not sorgente:
        return None                       # senza sorgente non si sa
    originale = os.path.join(sorgente, relativo)
    if not os.path.exists(originale):
        return None
    nomi, errore = dipendenze(originale)
    if nomi is None:
        return None
    if lib in nomi:
        return True
    # ⚠️ Il confezionamento RISCRIVE la radice: il binario di origine dice
    # <vecchia>/postgresql/lib/libpq.5.dylib e quello confezionato
    # <nuova>/postgresql/lib/libpq.5.dylib. Un confronto alla lettera li
    # chiamava diversi e concludeva che la dipendenza l'avevamo introdotta
    # noi, che e' il contrario del vero. Si normalizzano le sole radici note.
    atteso = normalizza(lib, radici)
    return atteso in set(normalizza(x, radici) for x in nomi)


def main():
    if len(sys.argv) not in (4, 5, 6):
        print("uso: verify-isolation.py <specchio> <payload> <radice-installazione> "
              "[<sorgente> [<radice-vecchia>]]",
              file=sys.stderr)
        return 2
    specchio, payload, radice = (os.path.abspath(p).rstrip("/") for p in sys.argv[1:4])
    sorgente = os.path.abspath(sys.argv[4]).rstrip("/") if len(sys.argv) > 4 else None
    vecchia = sys.argv[5].rstrip("/") if len(sys.argv) > 5 else None
    # Le radici che il confezionamento riscrive, e solo quelle.
    radici = tuple(r for r in (radice, sorgente, vecchia) if r)
    for cartella in (specchio, payload):
        if not os.path.isdir(cartella):
            print("  %s non e' una cartella" % cartella, file=sys.stderr)
            return 2

    problemi = []

    # ---- 1. la configurazione ------------------------------------------
    esaminate = 0
    fuori = 0
    non_valutabili = 0
    for (file_conf, numero, direttiva, valore, grezzo, errore, condizionale,
         attivo) in percorsi_nella_configurazione(specchio):
        dove = os.path.relpath(file_conf, specchio)
        if errore:
            # ⚠️ Quello che non si sa leggere si DICHIARA. Prima le righe non
            # interpretabili e i percorsi relativi sparivano in silenzio, e il
            # conteggio finale diceva "0 fuori" su una configurazione che non
            # era stata guardata tutta.
            non_valutabili += 1
            problemi.append("%s:%d %s: %s" % (dove, numero, errore, grezzo or ""))
            continue
        esaminate += 1

        if dentro(valore, specchio, payload):
            if direttiva in DEVE_ESISTERE and attivo and not condizionale \
                    and not any(c in grezzo for c in "*?[") \
                    and not os.path.exists(valore):
                problemi.append("%s:%d %s nomina %s, che non esiste"
                                % (dove, numero, direttiva, grezzo))
                fuori += 1
            continue

        ammessi = FUORI_AMMESSO.get(direttiva, ())
        if ammessi:
            # ⚠️ Si guardano tutte e due le forme. Il percorso normalizzato,
            # perche' /usr/lib/../../opt/homebrew comincia per /usr/lib/ solo
            # finche' non lo si normalizza; e quello vero, perche' su macOS
            # /etc e' un link a /private/etc e un TypesConfig
            # /etc/mime.types, che e' legittimo, veniva bocciato.
            try:
                vero = os.path.realpath(valore)
            except OSError:
                vero = valore
            if valore.startswith(ammessi) or vero.startswith(ammessi):
                continue

        fuori += 1
        problemi.append("%s:%d %s porta fuori dal pacchetto: %s"
                        % (dove, numero, direttiva, valore))

    print("  %d percorsi nominati dalla configurazione, %d fuori, %d non valutabili"
          % (esaminate, fuori, non_valutabili))

    # ---- 2. le librerie ------------------------------------------------
    binari = 0
    perse = 0                 # c'erano nella sorgente e nel pacchetto no: colpa nostra
    ereditate = []            # rotte da prima di noi, e VERIFICATO che lo fossero
    senza_percorso = []
    irrisolte = []            # con un @ che da qui non si sa sciogliere
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
            dove = os.path.relpath(intero, payload)
            eseguibile = os.access(intero, os.X_OK) and not nome.endswith(
                (".dylib", ".so", ".bundle"))

            for lib in libs:
                if lib.startswith("@"):
                    dove_puo, motivo = candidati(lib, intero, eseguibile)
                    if dove_puo is None:
                        irrisolte.append((dove, lib, motivo))
                        continue
                    # ⚠️ Vince il PRIMO che esiste, non "uno qualsiasi".
                    # dyld prova le LC_RPATH nell'ordine in cui stanno scritte:
                    # se la prima porta fuori dal pacchetto, e' quella che
                    # verra' caricata, e accettare perche' piu' avanti ce n'e'
                    # una buona vuol dire guardare un percorso che non verra'
                    # mai usato.
                    primo = None
                    for c in dove_puo:
                        if os.path.exists(c):
                            primo = c
                            break
                    if primo is not None:
                        # ⚠️ dentro() e non os.path.exists: un link dentro il
                        # payload che punta alla cartella sorgente esiste
                        # benissimo e non e' nel pacchetto.
                        if dentro(primo, payload):
                            continue
                        if primo.startswith(SISTEMA_LIB):
                            continue
                        if primo.startswith(radice + "/") and os.path.exists(
                                os.path.join(payload, os.path.relpath(primo, radice))):
                            continue
                        perse += 1
                        problemi.append("%s: %s risolve fuori dal pacchetto (%s)"
                                        % (dove, lib, primo))
                        continue
                    # Nessun candidato esiste nel pacchetto.
                    #
                    # ⚠️ La domanda non e' "la sorgente NOMINAVA questa
                    # dipendenza" ma "nella sorgente si RISOLVEVA". Un
                    # @loader_path/../lib/libssl.dylib c'e' in tutti e due, ma
                    # se la libreria stava nella sorgente e nel pacchetto no,
                    # l'abbiamo persa noi: prima finiva fra le "rotte gia'
                    # nella sorgente".
                    if sorgente:
                        nella_sorgente, _m = candidati(
                            lib, os.path.join(sorgente, dove), eseguibile)
                        if nella_sorgente and any(os.path.exists(c)
                                                  for c in nella_sorgente):
                            perse += 1
                            problemi.append("%s: %s si risolveva nella sorgente e nel "
                                            "pacchetto no" % (dove, lib))
                            continue
                    gia = dipendenza_gia_nella_sorgente(sorgente, dove, lib, radici)
                    if gia is True:
                        ereditate.append((dove, lib))
                    elif gia is False:
                        perse += 1
                        problemi.append("%s dipende da %s, che nella sorgente non "
                                        "c'era: l'ha introdotta il confezionamento"
                                        % (dove, lib))
                    else:
                        irrisolte.append((dove, lib, "nessun candidato esiste"))
                    continue

                if not lib.startswith("/"):
                    # Nome senza percorso, come "libgd.dylib": lo risolve dyld
                    # a runtime con i suoi percorsi di ripiego. Viene dal build
                    # upstream e cambiarlo vorrebbe dire ricompilare.
                    senza_percorso.append((dove, lib))
                    continue
                if lib.startswith(SISTEMA_LIB):
                    continue
                if lib.startswith(radice + "/"):
                    # Dopo l'installazione quel percorso sara' questo file, e
                    # deve esserci.
                    relativo = os.path.relpath(lib, radice)
                    _atteso = os.path.join(payload, relativo)
                    # ⚠️ dentro() e non exists(): un link nel payload che
                    # punta alla cartella sorgente esiste e non e' nel
                    # pacchetto.
                    if os.path.exists(_atteso) and dentro(_atteso, payload):
                        continue
                    if sorgente and os.path.exists(os.path.join(sorgente, relativo)):
                        perse += 1
                        problemi.append("%s dipende da %s: c'era nella sorgente e il "
                                        "pacchetto non la contiene" % (dove, lib))
                        continue
                else:
                    # Un percorso assoluto che non e' ne' di sistema ne' nostro:
                    # la macchina di build di qualcun altro. Se esiste qui e'
                    # un riferimento all'installazione locale.
                    if os.path.exists(lib):
                        perse += 1
                        problemi.append("%s dipende da %s, che esiste solo su questa "
                                        "macchina" % (dove, lib))
                        continue

                # Non esiste da nessuna parte. ⚠️ "Ereditata" si DIMOSTRA
                # guardando lo stesso binario nella sorgente, non si deduce
                # dall'assenza: un riferimento appena introdotto da una nostra
                # patch non esiste da nessuna parte esattamente come uno rotto
                # da sempre.
                gia = dipendenza_gia_nella_sorgente(sorgente, dove, lib, radici)
                if gia is True:
                    ereditate.append((dove, lib))
                elif gia is False:
                    perse += 1
                    problemi.append("%s dipende da %s, che nella sorgente non c'era: "
                                    "l'ha introdotta il confezionamento" % (dove, lib))
                else:
                    irrisolte.append((dove, lib,
                                      "non esiste, e la sorgente non e' consultabile"))

    print("  %d Mach-O esaminati, %d dipendenze perse dal confezionamento"
          % (binari, perse))
    if senza_percorso:
        print("  %d dipendenze per nome, senza percorso: le risolve dyld"
              % len(senza_percorso))
        for dove, lib in senza_percorso[:3]:
            print("      %s -> %s" % (dove, lib))
        if len(senza_percorso) > 3:
            print("      e altre %d" % (len(senza_percorso) - 3))
    if irrisolte:
        # ⚠️ Non un via libera. Sono dipendenze di cui NON si e' potuto dire
        # niente, e finche' sono elencate il controllo non sta affermando che
        # il pacchetto e' autosufficiente.
        print("  %d dipendenze non valutabili da qui:" % len(irrisolte))
        for dove, lib, motivo in irrisolte[:6]:
            print("      %s -> %s (%s)" % (dove, lib, motivo))
        if len(irrisolte) > 6:
            print("      e altre %d" % (len(irrisolte) - 6))
    if ereditate:
        # Non un problema, ma nemmeno una cosa da nascondere: e' un elenco di
        # pezzi dello stack che non funzionerebbero se qualcuno li usasse.
        print("  %d dipendenze rotte GIA' NELLA SORGENTE, verificato binario per "
              "binario:" % len(ereditate))
        visti = {}
        for dove, lib in ereditate:
            visti.setdefault(lib, []).append(dove)
        for lib in sorted(visti)[:6]:
            print("      %s (%d file)" % (lib, len(visti[lib])))
        if len(visti) > 6:
            print("      e altre %d librerie" % (len(visti) - 6))

    if irrisolte:
        # ⚠️ Non e' un elenco informativo: finche' c'e' una dipendenza di cui
        # non si e' potuto dire niente, il pacchetto non si puo' chiamare
        # autosufficiente. Il builder usa l'esito per decidere se andare
        # avanti fino al timbro, e un dubbio non e' un via libera.
        problemi.append("%d dipendenze non valutabili: vedi l'elenco qui sopra"
                        % len(irrisolte))
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
