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
# ⚠️ Maiuscole come le scrive Apache: "-DSSL" definisce SSL, e i nomi dei
# parametri sono sensibili alle maiuscole. Abbassandoli, "Define extra"
# rendeva attivo un <IfDefine EXTRA> che Apache considera un altro nome.
DEFINE_ATTIVI = ("SSL", "PHP")

# Le direttive che al posto di un percorso accettano anche PAROLE CHIAVE.
# ⚠️ Solo per queste vale "senza barra e inesistente non e' un percorso".
# Applicata a tutte, quella regola faceva sparire dal controllo un
# AuthUserFile che non esiste ancora e un CustomLog verso un link rotto, che
# sono riferimenti da guardare, non parole.
# ⚠️ ErrorLog e i log accettano "syslog" e "syslog:local7": senza, quelle
# stringhe venivano contate come file dentro il pacchetto e il totale saliva
# senza che nessun percorso in piu' fosse stato guardato.
# ⚠️ Non un elenco di direttive, ma le parole chiave VERE di ognuna. Con
# l'elenco piatto, "CustomLog escape" -- dove escape e' un collegamento rotto
# che esce dal pacchetto -- veniva scartato come se fosse una parola. Quello
# che conta e' la forma dell'argomento, non a quale direttiva appartiene.
PAROLE_CHIAVE = {
    # ⚠️ syslog e' una destinazione di ErrorLog, non di CustomLog: li'
    # "CustomLog syslog common" nomina un file relativo, e trattarlo come
    # parola lo faceva sparire dal controllo. Provato: un Apache di prova con
    # quella riga crea davvero il file "syslog" nella radice.
    "errorlog":            ("syslog",),
    "sslpassphrasedialog": ("builtin",),
    "sslcryptodevice":     ("builtin",),
    "sslrandomseed":       ("builtin",),
    "sslsessioncache":     ("none", "nonenotnull"),
    "sslstaplingcache":    ("none",),
    "mutex":               ("default", "none", "posixsem", "sysvsem", "sem",
                            "pthread", "fcntl", "flock", "file"),
    "rewritemap":          (),
}


def e_parola_chiave(direttiva, pezzo):
    """Vero se l'argomento e' una parola della direttiva, non un percorso."""
    ammesse = PAROLE_CHIAVE.get(direttiva)
    if ammesse is None:
        return False
    minuscolo = pezzo.lower()
    for parola in ammesse:
        if minuscolo == parola or minuscolo.startswith(parola + ":"):
            return True
    if direttiva != "rewritemap":
        return False
    # ⚠️ "dbm=sdbm:mapfile" nomina un file: l'eccezione generica "rewritemap
    # con i due punti e' una parola" lo scartava. Le mappe che non nominano
    # file sono int: e quelle senza due punti.
    testa = pezzo.split(":", 1)[0].lower()
    if testa.startswith("dbm=") or testa in ("txt", "rnd", "dbm", "prg", "dbd",
                                             "fastdbd"):
        return False
    return ":" in pezzo

# I prefissi che introducono un percorso, anche relativo: "file:entropia",
# "txt:mappa". "int:" e' una mappa interna e non nomina nessun file.
# ⚠️ fcntl e flock erano assenti: "Mutex fcntl:escape default" nomina un
# file esattamente come "file:escape", e con escape collegamento verso una
# cartella temporanea fuori dallo specchio il controllo usciva 0 contando il
# solo ServerRoot. La forma file: veniva segnalata e le altre due no.
PREFISSI_CON_PERCORSO = ("file", "txt", "rnd", "dbm", "prg", "exec", "shmcb", "dbd",
                         "fcntl", "flock")

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
        # ⚠️ "|$" non e' un programma che si chiama "$qualcosa": il dollaro
        # dice ad Apache di passare per la shell, e quello che segue e' il
        # programma. Conservandolo, /opt/homebrew/bin/x diventava un percorso
        # relativo sotto ServerRoot e il controllo lo dichiarava interno.
        if pezzo.startswith("$"):
            pezzo = pezzo[1:].strip()
        if pezzo:
            trovati.append((pezzo.split()[0], True))
        return trovati
    if pezzo.startswith("/"):
        trovati.append((pezzo, True))
        return trovati
    # meccanismo:/percorso, con eventuali parametri fra parentesi in coda
    if ":" in pezzo:
        testa, coda = pezzo.split(":", 1)
        coda = re.sub(r"\(.*\)$", "", coda)
        # ⚠️ Un prefisso noto introduce un percorso anche quando e' relativo:
        # "SSLRandomSeed startup file:entropia" e "RewriteMap m txt:mappa"
        # nominano due file, e sparivano perche' non cominciavano con "/".
        _t = testa.lower()
        if _t.startswith("dbm="):
            _t = "dbm"
        if coda and (coda.startswith("/") or _t in PREFISSI_CON_PERCORSO):
            # ⚠️ "certo": il prefisso dice che e' un percorso, quindi il filtro
            # delle parole chiave non deve toccarlo. Senza, "file:entropia" e
            # "txt:mappa" sparivano perche' la coda non ha barre.
            trovati.append((coda, True))
            return trovati
    # ⚠️ Tutto il resto torna com'e': sono i percorsi RELATIVI a ServerRoot,
    # che chi chiama risolve. Scartandoli, i percorsi esaminati sullo staging
    # vero sono passati da 180 a 38 e il controllo usciva 0 lo stesso, cioe'
    # diceva "nessuno fuori" dopo aver guardato un quinto della configurazione.
    trovati.append((pezzo, False))
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
    define_attivi = set(DEFINE_ATTIVI)
    define_incerti = set()
    # ⚠️ I moduli CARICATI da un LoadModule in un ramo certamente attivo.
    # Senza, ogni <IfModule> restava ignoto e la prudenza costava una verifica
    # vera: httpd-ssl.conf e' incluso sotto <IfModule ssl_module>, quindi con
    # la pila ereditata il controllo "il certificato deve esistere" smetteva
    # di scattare. Era proprio il guasto del 7 settembre.
    #
    # Un modulo ASSENTE da qui resta ignoto, non inattivo: puo' essere
    # compilato dentro httpd invece che caricato, e questo file non lo sa.
    moduli_attivi = set()

    # ⚠️ Due insiemi diversi. ATTIVO e' quello che Apache legge davvero,
    # partendo da httpd.conf e seguendo gli Include: solo li' ha senso
    # pretendere che un modulo o un certificato ESISTA. Tutto il resto viene
    # letto lo stesso, perche' un percorso che porta fuori dal pacchetto e'
    # un problema anche in un file mai incluso, ma non se ne pretende
    # l'esistenza: etc/original/ e' la copia di sicurezza delle
    # configurazioni di partenza, e i suoi certificati non esistono e non
    # devono esistere.
    principale = os.path.join(etc, "httpd.conf")
    # ⚠️ Ogni file in coda porta con se' la PILA delle condizioni aperte nel
    # punto in cui e' stato incluso. Prima si accodava il solo percorso e il
    # file veniva letto con una pila vuota: un "Define EXTRA" dentro un file
    # incluso sotto <IfModule qualcosa-che-non-so> diventava CERTO, e un
    # <IfDefine !EXTRA> successivo veniva dichiarato inattivo. Apache usciva
    # 1 per l'Include obbligatorio mancante, il validatore 0.
    da_leggere = [(principale, [])] if os.path.exists(principale) else []
    attivi = set(os.path.realpath(f) for f, _ in da_leggere)
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
            intero, pila_ereditata = da_leggere.pop(0)
            attivo = True
        else:
            intero = altri.pop(0)
            pila_ereditata = []
            attivo = False
        vero = os.path.realpath(intero)
        # ⚠️ Visto PER CONTESTO, non per percorso. Da quando la pila viaggia
        # con il file, lo stesso file incluso prima sotto <IfDefine NEVER> e
        # poi senza condizioni veniva letto una volta sola, nel contesto
        # spento, e la seconda inclusione (quella che Apache esegue) veniva
        # saltata come gia' vista. Apache usciva 1, il validatore 0.
        chiave = (vero, tuple(pila_ereditata))
        if chiave in visti:
            continue
        visti.add(chiave)
        try:
            testo = open(intero, encoding="utf-8", errors="replace").read()
        except OSError as errore:
            trovati.append((intero, 0, None, None, None, str(errore), False, True, True))
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

        pila = list(pila_ereditata)
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

            # ⚠️ Una pila vera, con un valore per ogni contenitore aperto.
            # Prima si teneva un contatore e un elenco delle sole condizioni
            # ignote: chiudendo una condizione NOTA annidata si toglieva
            # dall'elenco quella esterna, e la profondita' andava fuori passo.
            if minuscola.startswith(("<ifdefine", "<ifmodule", "<ifversion")):
                if minuscola.startswith("<ifdefine"):
                    nome_def = re.sub(r"^<ifdefine\s+", "", pulita, flags=re.I).rstrip(">").strip()
                    negato = nome_def.startswith("!")
                    nome_def = nome_def.lstrip("!").strip().strip('"')
                    # ⚠️ <IfDefine !SSL> con SSL attivo e' un blocco che Apache
                    # NON legge: pretendere che i suoi file esistano e' un
                    # falso allarme. La negazione va letta, non tolta.
                    if nome_def in define_incerti and nome_def not in define_attivi:
                        pila.append(None)
                        # ⚠️ Si segnala solo dove l'incertezza cambia qualcosa.
                        # Dentro un ramo gia' CERTAMENTE falso il blocco non
                        # viene letto comunque, e in un .conf che nessuno
                        # include non partecipa alla configurazione attiva:
                        # in tutti e due i casi Apache esce 0, e dichiarare
                        # "non valutabile" rendeva non confezionabile un
                        # pacchetto sano. Il difetto era che il record veniva
                        # consumato senza guardare ne' la pila ne' attivo.
                        if attivo and False not in pila:
                            trovati.append((intero, numero, "ifdefine", None, nome_def,
                                            "la condizione dipende da un Define sotto "
                                            "una condizione non valutabile",
                                            True, attivo, True))
                    else:
                        pila.append((nome_def in define_attivi) != negato)
                elif minuscola.startswith("<ifmodule"):
                    nome_mod = re.sub(r"^<ifmodule\s+", "", pulita, flags=re.I).rstrip(">").strip()
                    negato_mod = nome_mod.startswith("!")
                    nome_mod = nome_mod.lstrip("!").strip().strip('"')
                    if nome_mod in moduli_attivi:
                        pila.append(True != negato_mod)
                    else:
                        # ⚠️ None, non False: di un modulo che non abbiamo
                        # visto caricare non si sa se sia attivo, perche'
                        # potrebbe essere compilato dentro httpd. Appiattirlo
                        # su "inattivo" faceva sparire un Define scritto
                        # dentro un modulo davvero caricato.
                        pila.append(None)
                else:
                    pila.append(None)
                continue
            if minuscola.startswith(("</ifdefine", "</ifmodule", "</ifversion")):
                if pila:
                    pila.pop()
                continue

            # ⚠️ Define crea una condizione attiva: <IfDefine EXTRA> dopo
            # "Define EXTRA" conta, e prima passava per ignoto.
            # ⚠️ Le direttive di Apache sono INSENSIBILI alle maiuscole, i
            # loro argomenti no. Correggendo i parametri avevo reso sensibile
            # anche il nome della direttiva: "define EXTRA" e "<IFDEFINE SSL>"
            # smettevano di essere riconosciuti e il validatore usciva 0 dove
            # Apache usciva 1.
            # LoadModule in un ramo certamente attivo rende NOTO un
            # <IfModule> che usa il nome simbolico (ssl_module).
            #
            # ⚠️ Solo quello. La forma "mod_ssl.c" e' il nome del file
            # SORGENTE compilato dentro il modulo, e il nome del .so su disco
            # non lo dimostra: un mod_authz_core.so rinominato mod_imaginary.so
            # veniva registrato come mod_imaginary.c, che Apache non riconosce,
            # e il validatore scartava un ramo che Apache esegue. Una
            # condizione scritta con il nome sorgente resta IGNOTA, cioe'
            # prudente, invece che certa per deduzione.
            _mod = re.match(r"^loadmodule\s+(\S+)\s+\S+", pulita, re.I)
            if _mod and all(x is True for x in pila):
                moduli_attivi.add(_mod.group(1).strip('"'))

            _def = re.match(r"^define\s+(\S+)", pulita, re.I)
            if _def:
                # ⚠️ \s per la tabulazione, e solo se il ramo e' ATTIVO: un
                # "Define EXTRA" dentro un <IfDefine> mai vero non definisce
                # niente, e registrarlo faceva considerare attivo il blocco
                # che lo nomina.
                _nome = _def.group(1).strip('"')
                if all(x is True for x in pila):
                    define_attivi.add(_nome)
                elif False not in pila:
                    # ⚠️ Sotto una condizione IGNOTA non si sa se il Define
                    # avvenga. Registrarlo lo dava per certo, e un
                    # <IfDefine !EXTRA> successivo veniva giudicato inattivo:
                    # il controllo usciva 0 dove Apache usciva 1. Qui si tiene
                    # da parte come incerto, e chi lo nomina diventa incerto
                    # a sua volta.
                    define_incerti.add(_nome)
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
                                # ⚠️ Nove campi, non otto: il chiamante ne
                                # aspetta nove e questo ramo ne dava otto, per
                                # cui una direttiva con le virgolette non
                                # chiuse faceva morire il controllo con
                                # ValueError invece di segnalarla.
                                "riga non interpretabile",
                                (not all(x is True for x in pila)), attivo, True))
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
            if direttiva == "mutex":
                # ⚠️ "Mutex default ssl-cache": il secondo argomento e' il NOME
                # del mutex, non un file, e veniva contato come percorso. Solo
                # il primo puo' portare un percorso, e solo con un prefisso.
                if len(pezzi) > 1:
                    grezzi.extend(percorsi_nell_argomento(pezzi[1]))
            elif quale == 0 or direttiva in MULTI_ARGOMENTI:
                for pezzo in pezzi[1:]:
                    grezzi.extend(percorsi_nell_argomento(pezzo))
            elif len(pezzi) > quale:
                grezzi.extend(percorsi_nell_argomento(pezzi[quale]))

            for grezzo, certo in grezzi:
                if not grezzo or grezzo.startswith("|"):
                    continue                    # un programma, non un file
                if "${" in grezzo or "%" in grezzo:
                    # Una variabile che qui non si sa espandere: si dice, non
                    # si scarta.
                    trovati.append((intero, numero, direttiva, None, grezzo,
                                    "contiene una variabile non espandibile",
                                    (not all(x is True for x in pila)), attivo, certo))
                    continue
                # ⚠️ normpath anche sugli assoluti: /usr/lib/../../opt/homebrew
                # comincia per /usr/lib/, che e' un prefisso ammesso, e
                # passava il controllo prima di essere normalizzato.
                assoluto = os.path.normpath(grezzo) if grezzo.startswith("/") \
                    else os.path.normpath(os.path.join(serverroot, grezzo))
                trovati.append((intero, numero, direttiva, assoluto, grezzo, None,
                                (not all(x is True for x in pila)), attivo, certo))

                if direttiva == "include" and any(c in grezzo for c in "*?["):
                    # ⚠️ Include con un glob che non trova niente FERMA Apache
                    # all'avvio: solo IncludeOptional lo consente. Il commento
                    # diceva "un glob vuoto e' lecito" confondendo le due
                    # direttive, e il caso passava.
                    if not glob.glob(assoluto):
                        trovati.append((intero, numero, direttiva, None, grezzo,
                                        "Include con un glob che non trova nessun file",
                                        (not all(x is True for x in pila)), attivo, True))
                if attivo and direttiva in ("include", "includeoptional"):
                    # ⚠️ Il contenuto degli inclusi va letto: un .inc che
                    # carica un modulo da /opt/homebrew non veniva mai aperto.
                    for incluso in sorted(glob.glob(assoluto)):
                        if os.path.isdir(incluso):
                            for c, _, n in os.walk(incluso):
                                for x in sorted(n):
                                    da_leggere.append((os.path.join(c, x), list(pila)))
                                    attivi.add(os.path.realpath(os.path.join(c, x)))
                        elif os.path.isfile(incluso):
                            da_leggere.append((incluso, list(pila)))
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


def _carica_nomi_di_partenza():
    """Le coppie da tools/nomi-a-monte.py, lette da li' e non ricopiate: due
    elenchi uguali scritti in due file divergono alla prima correzione."""
    import importlib.util
    qui = os.path.join(os.path.dirname(os.path.abspath(__file__)), "nomi-a-monte.py")
    spec = importlib.util.spec_from_file_location("nomi_a_monte", qui)
    modulo = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(modulo)
    return [(a.decode(), b.decode()) for a, b in modulo.COPPIE]


NOMI_DI_PARTENZA = _carica_nomi_di_partenza()


def _rinomina(percorso):
    for vecchio, nuovo in NOMI_DI_PARTENZA:
        percorso = percorso.replace(vecchio, nuovo)
    return percorso


def normalizza(percorso, radici):
    """Il percorso con la radice riportata a una forma sola.

    ⚠️ Prima si confrontavano gli ultimi tre pezzi del percorso, e tre pezzi
    uguali non vogliono dire stesso percorso: /review-a/team/lib/manca.dylib e
    /review-b/team/lib/manca.dylib finivano per essere "la stessa dipendenza"
    e una libreria mai vista veniva dichiarata ereditata. Si normalizzano solo
    le riscritture CHE SAPPIAMO essere state fatte, e per il resto si
    confronta alla lettera.
    """
    # ⚠️ Anche i nomi di partenza sono una riscrittura che SAPPIAMO fatta:
    # tools/nomi-a-monte.py li sostituisce a parita' di lunghezza prima della
    # firma. Senza applicarla ai due lati, una dipendenza rotta ereditata si
    # chiamava in un modo nel pacchetto e in un altro nella sorgente, e veniva
    # dichiarata persa dal confezionamento.
    for vecchio, nuovo in NOMI_DI_PARTENZA:
        percorso = percorso.replace(vecchio, nuovo)
    for vecchia in radici:
        vecchia = vecchia and _rinomina(vecchia)
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
         attivo, certo) in percorsi_nella_configurazione(specchio):
        dove = os.path.relpath(file_conf, specchio)
        if errore:
            # ⚠️ Quello che non si sa leggere si DICHIARA. Prima le righe non
            # interpretabili e i percorsi relativi sparivano in silenzio, e il
            # conteggio finale diceva "0 fuori" su una configurazione che non
            # era stata guardata tutta.
            non_valutabili += 1
            problemi.append("%s:%d %s: %s" % (dove, numero, errore, grezzo or ""))
            continue
        # ⚠️ Non tutto quello che sta al posto di un percorso E' un percorso.
        # "SSLPassPhraseDialog builtin", "SSLSessionCache none", "Mutex
        # default": parole chiave che finivano risolte come file sotto
        # ServerRoot e contate fra i percorsi esaminati. Il conteggio saliva
        # senza che nessun percorso in piu' fosse stato guardato, ed e' il
        # numero su cui ci si accorge di quello che il controllo non vede.
        #
        # Si riconosce un percorso da una barra, o dal fatto che esista. Per
        # le direttive che DEVONO nominare un file la regola non vale: li' un
        # nome senza barra e' un percorso relativo, e se non esiste e' un
        # problema, non una parola chiave.
        # ⚠️ Niente os.path.exists: l'esistenza per caso di un file chiamato
        # "builtin" non cambia il significato della direttiva, e lo faceva
        # contare come percorso.
        if not certo and "/" not in grezzo and e_parola_chiave(direttiva, grezzo):
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
                        # ⚠️ Anche qui dentro(), non exists(): il ramo che
                        # rimappa un candidato sotto la radice di
                        # installazione era rimasto scoperto, e un link nel
                        # payload che punta alla cartella sorgente esisteva
                        # benissimo senza essere nel pacchetto.
                        if primo.startswith(radice + "/"):
                            _rimappato = os.path.join(payload,
                                                      os.path.relpath(primo, radice))
                            if os.path.exists(_rimappato) and dentro(_rimappato, payload):
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
