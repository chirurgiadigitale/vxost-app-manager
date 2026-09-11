#!/bin/bash
#
# Builds a redistributable VXOST stack: Apache, MariaDB, PHP, Perl, ProFTPD and
# phpMyAdmin, together with this app and the redesigned dashboard.
#
# The point of this script is what it leaves out. It is built from the local
# VXOST installation, which on a working machine is full of the owner's
# projects, databases, logs and virtual hosts. None of that may ship.
#
#   - htdocs is never copied; a clean dashboard is put in its place
#   - var/mysql is never copied. Excluding the database folders would not be
#     enough: InnoDB keeps every table's data in ibdata1, so a fresh database
#     is created from scratch with mysql_install_db
#   - logs, PID files, sockets and backups are excluded
#   - virtual hosts are reset to the stock file
#
# The result is verified afterwards: the build fails if any personal string
# survives into the package.
#
# Usage: bash tools/build-stack.sh
set -euo pipefail

# The installation root is detected, not written down.
#
# While the folders are being renamed the old path and the new one both exist,
# on different machines, and a fixed path makes this script fail on half of
# them with an error that only says a directory is missing. Same rule the app
# follows in XPPaths: no install path is hard-coded outside the code that
# detects it. Getting this wrong in the app cost an afternoon of silent
# failures, so it is not repeated here.
SOURCE=""
for _candidate in "/Applications/VXOST/vxostfiles" "/Applications/XAMPP/xamppfiles"; do
    [ -d "$_candidate" ] && { SOURCE="$_candidate"; break; }
done
if [ -z "$SOURCE" ]; then
    echo "No installation found under /Applications. Nothing to build from." >&2
    exit 1
fi
# La radice web si rileva come tutto il resto, e per lo stesso motivo: dopo la
# rinomina si chiama www, prima si chiamava htdocs, e le due convivono su
# macchine diverse.
#
# ⚠️ E se non si trova, si ferma. Un ciclo di copia che non trova niente e
# tira dritto e' esattamente il difetto che ha fatto uscire un pacchetto da
# 327 MB senza lo script di controllo: sembrava completo e non avviava un solo
# servizio.
DASHBOARD_REPO=""
for _name in "www" "htdocs"; do
    [ -d "$SOURCE/$_name" ] && { DASHBOARD_REPO="$SOURCE/$_name"; break; }
done
if [ -z "$DASHBOARD_REPO" ]; then
    echo "No web root under $SOURCE: neither www nor htdocs. Nothing to copy." >&2
    exit 1
fi

# Nel pacchetto si chiama sempre www: e' il nome scelto, e un pacchetto che
# uscisse con htdocs rimetterebbe in circolo il nome vecchio.
WEBROOT="www"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
STAGE="$HERE/build/stack"
PAYLOAD="$STAGE/vxostfiles"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$HERE/Resources/Info.plist")"

# Strings that must never appear in the finished package.
#
# This list is BUILT AT RUNTIME and is deliberately not hard-coded: writing the
# customer names into a public repository would leak exactly the data the check
# exists to protect. It is also self-maintaining, a project added tomorrow is
# covered without touching this file.
#
# Anything that cannot be derived (a company name, a former project no longer
# on disk) goes in tools/forbidden.local.txt, one entry per line, which is
# git-ignored and never leaves this machine.
FORBIDDEN=()

# 1. Every project folder served by the local web root. Both names are checked
#    while the folder is being renamed from progetti to projects.
for _dir in projects progetti; do
    [ -d "$DASHBOARD_REPO/$_dir" ] || continue
    while IFS= read -r name; do
        # Only folders. The listing page index.php lives next to the projects,
        # and taking it as a name to forbid made the check report every PHP
        # file in the package.
        [ -d "$DASHBOARD_REPO/$_dir/$name" ] || continue
        # Short names are skipped: as a substring they match ordinary words and
        # would fail every build on a false positive.
        [ ${#name} -ge 5 ] && FORBIDDEN+=("$name")
    done < <(ls "$DASHBOARD_REPO/$_dir" 2>/dev/null | grep -v '^\.')
done

# 2. The identity of the machine doing the build. $HOME is used rather than
#    $USER, which as a bare substring would match unrelated words.
FORBIDDEN+=("$HOME")
_hostname="$(scutil --get LocalHostName 2>/dev/null || hostname -s 2>/dev/null || true)"
[ ${#_hostname} -ge 5 ] && FORBIDDEN+=("$_hostname")

# 3. Private additions, if the file is there.
if [ -f "$HERE/tools/forbidden.local.txt" ]; then
    while IFS= read -r line; do
        case "$line" in ''|\#*) continue ;; esac
        FORBIDDEN+=("$line")
    done < "$HERE/tools/forbidden.local.txt"
fi

step() { printf "\n\033[1m%s\033[0m\n" "$*"; }

# ---------------------------------------------------------------- prepare ---

step "Preparing a clean staging area"
rm -rf "$STAGE"
mkdir -p "$PAYLOAD"

# --------------------------------------------------------------- binaries ---

step "Copying the stack (this takes a minute)"
for dir in bin sbin lib libexec modules share etc man licenses phpmyadmin cgi-bin error icons; do
    [ -d "$SOURCE/$dir" ] || continue
    printf "  %s\n" "$dir"
    # Sockets and caches inside phpmyadmin/tmp belong to the running instance.
    # ⚠️ ssl.key e ssl.crt non escono da questa macchina, mai.
    #
    # Il certificato di sviluppo lo firma mkcert e porta scritto dentro il
    # nome di chi l'ha generato e quello del suo Mac: spedirlo vorrebbe dire
    # mostrare quel nome nel certificato di ogni utente. La chiave privata e'
    # peggio ancora: se la stessa chiave sta in tutte le installazioni del
    # mondo, chi la estrae dal pacchetto puo' intercettare l'HTTPS locale di
    # chiunque altro l'abbia installato. Una chiave condivisa non e' una
    # chiave.
    #
    # Ognuno genera le sue al primo uso: il pulsante "Attiva SSL" nell'app
    # chiama mkcert sulla macchina di chi lo preme.
    #
    # ⛔ Si escludono le due cartelle, non "*.crt" ovunque:
    # share/curl/curl-ca-bundle.crt e' l'elenco delle autorita' di cui curl e
    # PHP si fidano. Toglierlo non spedisce una chiave in meno, rompe la
    # verifica di ogni HTTPS in uscita — e lo fa in silenzio.
    rsync -a --quiet \
          --exclude "tmp/" --exclude "*.sock" --exclude "*.pid" \
          --exclude "*.log" --exclude "*.err" \
          --exclude "*.bak" --exclude "*.bak-*" --exclude "*.bak.*" \
          --exclude "*.orig" --exclude "*.save" --exclude "*~" \
          --exclude "*.old" --exclude "*.backup" \
          --exclude "ssl.key/" --exclude "ssl.crt/" \
          "$SOURCE/$dir" "$PAYLOAD/" 2>/dev/null || \
    cp -R "$SOURCE/$dir" "$PAYLOAD/"

    # Il ripiego con cp non conosce le esclusioni: si rifanno a mano, tutte.
    #
    # ⚠️ Fino al 07/09/2026 questa pulizia ne copriva tre su nove: chiavi e
    # backup. Restavano fuori tmp/, i .log, i .err, i socket e i pid, cioe'
    # esattamente i file che raccontano la macchina di chi ha costruito il
    # pacchetto — percorsi, nomi di database, a volte query intere dentro un
    # error_log. Un rsync fallito e' silenzioso: `|| cp` non stampa niente, e
    # il pacchetto sarebbe uscito lo stesso.
    rm -rf "$PAYLOAD/$dir/ssl.key" "$PAYLOAD/$dir/ssl.crt"
    find "$PAYLOAD/$dir" -type d -name tmp -prune -exec rm -rf {} + 2>/dev/null || true

    # A stray backup is enough to leak every virtual host ever configured.
    find "$PAYLOAD/$dir" \( -name "*.bak*" -o -name "*.orig" -o -name "*.save" \
         -o -name "*.old" -o -name "*~" -o -name "*.backup" \
         -o -name "*.log" -o -name "*.err" \
         -o -name "*.sock" -o -name "*.pid" \) -delete 2>/dev/null || true
done

printf "  control scripts\n"
# ⚠️ This used to look for a file called "vxost" and, on a machine that still
# carries the old layout, found nothing: the package shipped with no control
# script at all and could not start a single service. Whatever the script is
# called at the source, it ships as vxost.
_control=""
for _name in vxost xampp lampp; do
    if [ -f "$SOURCE/$_name" ]; then
        cp "$SOURCE/$_name" "$PAYLOAD/vxost"
        chmod 755 "$PAYLOAD/vxost"
        _control="$_name"
        break
    fi
done
if [ -z "$_control" ]; then
    echo "  no control script found in $SOURCE" >&2
    exit 1
fi
printf "    %s -> vxost\n" "$_control"
[ -f "$SOURCE/properties.ini" ] && cp "$SOURCE/properties.ini" "$PAYLOAD/"

# The nineteen scripts under share/ and the control script next to them still
# carry the old name, inside and out. They only talk to each other, so renaming
# the whole set is safe. This also swaps in the replacement for checkmysqlport.
python3 "$HERE/tools/brand-stack.py" "$PAYLOAD" || exit 1
[ -f "$SOURCE/lib/VERSION" ] && cp "$SOURCE/lib/VERSION" "$PAYLOAD/lib/VERSION"

# ------------------------------------------------------------------ state ---

# ⛔ I flag di stato sono della macchina che ha costruito, non del pacchetto.
#
# etc/vxost/ raccoglie file vuoti che dicono allo script cosa fare al prossimo
# avvio. Due di questi, nello staging del 05/09, erano rimasti dalla macchina
# di chi ha costruito:
#
#   startftp      ProFTPD partirebbe su ogni installazione, senza che nessuno
#                 lo abbia chiesto. Un server FTP acceso e' una porta aperta,
#                 e la scelta di aprirla non la si eredita da uno sconosciuto.
#   rights_fixed  dice "i permessi sono gia' a posto" e fa saltare la
#                 riparazione al primo avvio. E' esattamente la riparazione
#                 che serve dopo il trascinamento nel Finder, che assegna
#                 tutto a chi ha trascinato: senza, mysqld non puo' scrivere
#                 nella propria cartella dati.
#
# startssl invece resta: e' quello che accende HTTPS, il certificato se lo
# genera la macchina che installa, e senza il file la porta 443 non
# risponderebbe piu' a nessuno.
step "Clearing the build machine's state flags"
for _flag in startftp rights_fixed; do
    if [ -e "$PAYLOAD/etc/vxost/$_flag" ]; then
        rm -f "$PAYLOAD/etc/vxost/$_flag"
        echo "  removed etc/vxost/$_flag"
    fi
done
for _flag in startftp rights_fixed; do
    if [ -e "$PAYLOAD/etc/vxost/$_flag" ]; then
        echo "!! etc/vxost/$_flag survived: it would ship with the package" >&2
        exit 1
    fi
done

step "Creating empty runtime folders"
# Logs, sockets and databases are recreated on first launch, never inherited.
#
# ⚠️ temp/mysql is not an empty folder like the others: my.cnf line 127 names
# it as tmpdir, and MariaDB refuses to start when it is missing. The package
# shipped temp/ empty until 04/09/2026, so on a clean install the daemon died
# before it could open its own error log — and an error log that does not
# exist reads as "MariaDB never even tried", which sends people rewriting
# datadir in my.cnf. On a machine with migrated databases that is how you
# lose them. mysql.server recreates it too, at every start (see below).
# ⚠️ var/proftpd: startProFTPD() nello script vxost redirige l'avvio su
# var/proftpd/start.err PRIMA di qualunque altra cosa. Senza la cartella la
# shell fallisce la redirezione, proftpd non viene nemmeno lanciato, e il
# messaggio parla di un file che non si puo' creare invece che di FTP.
mkdir -p "$PAYLOAD/logs" "$PAYLOAD/var" "$PAYLOAD/var/proftpd" "$PAYLOAD/temp" "$PAYLOAD/temp/mysql" "$PAYLOAD/backup"
touch "$PAYLOAD/logs/.gitkeep"

# --------------------------------------------------------------- web root ---

step "Installing a clean web root"
mkdir -p "$PAYLOAD/$WEBROOT"
# Only the redesigned dashboard, never the projects sitting next to it.
#
# ⚠️ The landing page is index.php, not index.html. This list asked for the
# .html one, which does not exist in the dashboard repo, so nothing was copied
# and the shipped web root had no index at all: https://virtualhost/ answered
# with a directory listing instead of the dashboard. Both names stay here —
# the page may well go back to being static one day — and .htaccess comes
# along because the redirects it carries are what makes the root work.
copied=0
index_copied=0
for item in dashboard index.php index.html .htaccess favicon.ico README.md; do
    if [ -e "$DASHBOARD_REPO/$item" ]; then
        cp -R "$DASHBOARD_REPO/$item" "$PAYLOAD/$WEBROOT/"
        copied=$((copied + 1))
        case "$item" in index.*) index_copied=1 ;; esac
    fi
done
if [ "$copied" -eq 0 ]; then
    echo "Nothing copied from $DASHBOARD_REPO: the package would ship an empty web root." >&2
    exit 1
fi
# Counting files is not enough: the dashboard folder alone satisfies the check
# above while the root of the site stays empty.
if [ "$index_copied" -eq 0 ]; then
    echo "No index page in $DASHBOARD_REPO: https://virtualhost/ would serve a listing." >&2
    exit 1
fi
# The upstream dashboard ships backups of the framework it used to use.
find "$PAYLOAD/$WEBROOT" \( -name "*.bak.*" -o -name "*.bak" -o -name "*-old.*" \) -delete 2>/dev/null || true

# ⚠️ L'indice dei progetti e' quello DINAMICO della dashboard, non una pagina
# scritta qui. Prima questo blocco generava un projects/index.html statico con
# "No projects yet": un utente aggiungeva un sito, e l'indice continuava a
# dire che non ce n'erano. projects/index.php legge le cartelle a ogni
# richiesta e mostra lo stato di partenza da solo quando sono zero; la sua
# .htaccess porta il DirectoryIndex verso browse.php e i filtri sui dump.
# Le cartelle dei progetti di questa macchina NON si copiano: solo i due file.
mkdir -p "$PAYLOAD/$WEBROOT/projects"
for _item in index.php .htaccess; do
    if [ ! -f "$DASHBOARD_REPO/projects/$_item" ]; then
        echo "!! $DASHBOARD_REPO/projects/$_item missing: the projects page would be a listing or a 404" >&2
        exit 1
    fi
    cp "$DASHBOARD_REPO/projects/$_item" "$PAYLOAD/$WEBROOT/projects/"
done
if [ -f "$PAYLOAD/$WEBROOT/projects/index.html" ]; then
    echo "!! a static projects/index.html got in: it would hide the dynamic index" >&2
    exit 1
fi
echo "  projects/: dynamic index and .htaccess from the dashboard"

# ------------------------------------------------------------ config reset ---

step "Resetting configuration to stock"
VHOSTS="$PAYLOAD/etc/extra/httpd-vhosts.conf"
if [ -f "$VHOSTS" ]; then
    cat > "$VHOSTS" <<'CONF'
#
# Virtual Hosts
#
# Add one block per project. The VXOST app reads this file and shows every
# project with the port it answers on.
#
# <VirtualHost *:4000>
#     DocumentRoot "/Applications/VXOST/vxostfiles/www/projects/my-site"
#     ServerName virtualhost
#     <Directory "/Applications/VXOST/vxostfiles/www/projects/my-site">
#         Options Indexes FollowSymLinks
#         AllowOverride All
#         Require all granted
#     </Directory>
# </VirtualHost>
#
# Remember to add a matching "Listen 4000" in httpd.conf.
CONF
fi

# httpd.conf itself can hold VirtualHost blocks, not only the vhosts file:
# every one of them is somebody's project and none may ship.
if [ -f "$PAYLOAD/etc/httpd.conf" ]; then
    python3 - "$PAYLOAD/etc/httpd.conf" <<'PYEOF'
import sys

# Parsed line by line rather than with a regex across the whole file. A
# multiline pattern matched a commented-out <VirtualHost> in the documentation
# near the top and swallowed everything down to the first real closing tag,
# taking "Listen 80" with it, which left Apache unable to start at all.
path = sys.argv[1]
out, depth = [], 0

for line in open(path, encoding="utf-8", errors="replace"):
    stripped = line.strip()
    commented = stripped.startswith("#")

    if not commented and stripped.lower().startswith("<virtualhost"):
        depth += 1
        continue
    if depth and not commented and stripped.lower().startswith("</virtualhost"):
        depth -= 1
        continue
    if depth:
        continue

    # Ports other than the standard two belong to somebody's projects.
    if not commented and stripped.lower().startswith("listen"):
        parts = stripped.split()
        port = parts[1].rsplit(":", 1)[-1] if len(parts) > 1 else ""
        if port not in ("80", "443"):
            continue
        # The package ships closed: loopback, written down, whatever the
        # build machine had. A bare "Listen 80" listens on every interface,
        # and a builder who had opened his own install to the wifi would
        # have shipped that choice to everyone. The app's exposure selector
        # is what opens it, on the user's say-so.
        rest = " ".join(parts[2:])
        line = "Listen 127.0.0.1:" + port + (" " + rest if rest else "") + "\n"

    # Includes reaching outside the distribution
    if not commented and stripped.lower().startswith("include") and "/apache2/" in stripped:
        continue

    out.append(line)

open(path, "w", encoding="utf-8").write("".join(out))
PYEOF
fi

# The same can happen in the SSL configuration.
if [ -f "$PAYLOAD/etc/extra/httpd-ssl.conf" ]; then
    python3 - "$PAYLOAD/etc/extra/httpd-ssl.conf" <<'PYEOF'
import re, sys
path = sys.argv[1]
text = open(path, encoding="utf-8", errors="replace").read()

# Same rule as httpd.conf: the 443 listener ships on loopback, explicitly.
text = re.sub(r"(?m)^([ \t]*)Listen[ \t]+(?:\S+:)?443\b(.*)$", r"\1Listen 127.0.0.1:443\2", text)

# Both folder names are matched. The folder was renamed from progetti to
# projects while this script already existed, and matching only the old name
# would have let every customer's DocumentRoot through into the package: the
# check would still have passed, because it was looking for a word that no
# longer appears on disk.
if re.search(r"progetti|projects", text, re.IGNORECASE):
    text = re.sub(r"\n?[ \t]*<VirtualHost\b(?:(?!</VirtualHost>).)*?(?:progetti|projects).*?</VirtualHost>[ \t]*\n?",
                  "\n", text, flags=re.DOTALL | re.IGNORECASE)
open(path, "w", encoding="utf-8").write(text)
PYEOF
fi

# The httpd binary carries a ServerRoot compiled into it, and it is still the
# old one: /Applications/XAMPP/xamppfiles. Started without -d and -f, Apache
# reads that config instead of ours — which on a machine coming from XAMPP is
# still on disk. What follows looks like anything but a wrong path: the old
# dashboard answers on port 80, a file dropped into www/ returns 404, and
# vxostfiles/logs stays empty because the running server is logging somewhere
# else entirely. Found on 21/08/2026 on the first migration done by someone
# who was not us, after four hours of looking at the wrong things.
#
# The fix goes in apachectl, whose own comment describes HTTPD as "the path to
# your httpd binary, including options if necessary". Everything that starts
# Apache goes through it — the vxost script, the app, the tools — so one line
# covers them all. The prefix is taken from the line itself rather than
# written here, so this keeps working if the install path ever changes.
# ---------------------------------------------------------- certificato ---
#
# ⚠️ Perche' e' uno script a se' e non due blocchi copiati. Il certificato
# serve a due chiamanti diversi, e in un ordine preciso:
#
#   1. lo script vxost, che in startApache() controlla la sintassi con
#      httpd -t -DSSL PRIMA di chiamare apachectl;
#   2. apachectl, per chiunque avvii Apache senza passare da li'.
#
# Finche' la generazione stava solo dentro apachectl, il punto 1 falliva per
# primo: etc/vxost/startssl arriva da upstream ed e' presente nel pacchetto,
# quindi -DSSL c'e' sempre, il controllo di sintassi non trovava
# etc/ssl.crt/server.crt, startApache tornava 1 e apachectl non veniva
# raggiunto mai. Su un Mac senza XAMPP installato Apache non partiva affatto,
# e il certificato che avrebbe risolto restava dietro la porta che non si
# apriva.
#
# La radice si deduce dal percorso dello script, non si scrive dentro: il
# pacchetto viene trascinato dal Finder e non e' detto che finisca dove
# pensava chi lo ha costruito.
# ⚠️ Una patch si verifica sulle righe attive, non sul testo del file.
#
# I controlli erano `grep -q "stringa" file`, e la stringa cercata compare
# anche nei commenti che la patch stessa inserisce: un `grep -q 'temp/mysql'`
# passa perche' la spiegazione qui sopra nomina temp/mysql, non perche' il
# mkdir ci sia. La verifica confermava se stessa, ed e' il tipo di controllo
# che da' sicurezza senza darne.
#
# Qui le righe commentate si tolgono prima di cercare.
has_active() {
    grep -v '^[[:space:]]*#' "$2" 2>/dev/null | grep -q -- "$1"
}

step "Installing the certificate generator"
cat > "$PAYLOAD/bin/vxost-ssl-init" <<'SSLEOF'
#!/bin/sh
# Genera il certificato di questa macchina, la prima volta che serve.
#
# Autofirmato, CN=virtualhost, dieci anni. Non esce niente da qui: un
# certificato dentro il pacchetto sarebbe lo stesso per tutti, chiave privata
# in chiaro, e chi la estraesse potrebbe intercettare l'HTTPS locale di ogni
# altra installazione. Una chiave condivisa non e' una chiave.
set -u

ROOT=$(cd "$(dirname "$0")/.." 2>/dev/null && pwd) || exit 1
CRT="$ROOT/etc/ssl.crt/server.crt"
KEY="$ROOT/etc/ssl.key/server.key"

# -s: un file vuoto non e' un certificato. Un tentativo interrotto lascia il
# file creato e vuoto, e senza questo controllo non verrebbe mai rifatto.
if [ -s "$CRT" ] && [ -s "$KEY" ]; then
    exit 0
fi

mkdir -p "$ROOT/etc/ssl.crt" "$ROOT/etc/ssl.key" || exit 1

OPENSSL="$ROOT/bin/openssl"
[ -x "$OPENSSL" ] || OPENSSL=/usr/bin/openssl
[ -x "$OPENSSL" ] || {
    echo "vxost-ssl-init: no openssl available" >&2
    exit 1
}

# Su un file temporaneo, poi spostato: se openssl fallisce a meta' non resta
# mezzo certificato che il controllo qui sopra scambierebbe per buono.
TMPCRT="$CRT.tmp.$$"
TMPKEY="$KEY.tmp.$$"
if ! "$OPENSSL" req -new -x509 -nodes -newkey rsa:2048 \
        -keyout "$TMPKEY" -out "$TMPCRT" \
        -days 3650 -subj '/CN=virtualhost' >/dev/null 2>&1; then
    rm -f "$TMPCRT" "$TMPKEY"
    echo "vxost-ssl-init: could not create the certificate" >&2
    exit 1
fi

chmod 600 "$TMPKEY"
chmod 644 "$TMPCRT"
mv "$TMPKEY" "$KEY" || exit 1
mv "$TMPCRT" "$CRT" || exit 1
exit 0
SSLEOF
chmod 755 "$PAYLOAD/bin/vxost-ssl-init"
if [ ! -x "$PAYLOAD/bin/vxost-ssl-init" ]; then
    echo "!! vxost-ssl-init was not installed: Apache would not start with -DSSL" >&2
    exit 1
fi
echo "  vxost-ssl-init installed"

if [ -f "$PAYLOAD/bin/apachectl" ]; then
    perl -pi -e "s|^HTTPD='(.*)/bin/httpd'\s*$|HTTPD='\$1/bin/httpd -d \$1 -f \$1/etc/httpd.conf'\n|" \
        "$PAYLOAD/bin/apachectl"

    # lynx is not in the package and this URL is never fetched, but "localhost"
    # in a shipped file is a name we no longer use anywhere.
    sed -i '' 's|http://localhost:80/server-status|http://127.0.0.1:80/server-status|' \
        "$PAYLOAD/bin/apachectl"

    if has_active "bin/httpd -d .* -f .*/etc/httpd.conf" "$PAYLOAD/bin/apachectl"; then
        echo "  apachectl: ServerRoot and config passed explicitly"
    else
        echo "!! apachectl was not patched: Apache would read XAMPP's config" >&2
        exit 1
    fi

    # HTTPS needs a certificate, and no package can carry one. A certificate
    # inside a DMG would be the same for everybody, private key in the clear:
    # whoever pulled it out could intercept the local HTTPS of every other
    # install. A shared key is not a key. So the two folders are excluded from
    # the copy — and until 04/09/2026 nothing created them again, which is a
    # different bug wearing the same clothes: httpd.conf starts with -DSSL,
    # finds no certificate and stops on
    #
    #   SSLCertificateFile: file 'etc/ssl.crt/server.crt' does not exist
    #
    # before serving anything. It stayed hidden because the same package also
    # read XAMPP's configuration, and XAMPP had certificates.
    #
    # It is generated here, on the machine that installs, the first time
    # Apache starts. apachectl is the one gate every caller goes through, so
    # this covers the app, the vxost script and the tools alike. The prefix
    # comes from the HTTPD line, patched or not, never written by hand.
    python3 - "$PAYLOAD/bin/apachectl" <<'PYEOF'
import re, sys

path = sys.argv[1]
text = open(path, encoding="utf-8", errors="replace").read()

if "VXOST_SSL_DIR" in text:          # already patched, nothing to do
    sys.exit(0)

match = re.search(r"^HTTPD='(.*?)/bin/httpd", text, re.MULTILINE)
if not match:
    sys.stderr.write("!! apachectl: no HTTPD line, cannot add the certificate step\n")
    sys.exit(1)
prefix = match.group(1)

block = f"""
# Il certificato di questa macchina, se manca. Lo stesso script viene chiamato
# dallo script vxost prima del suo controllo di sintassi: qui serve per
# chiunque avvii Apache senza passare di li'.
'{prefix}/bin/vxost-ssl-init' || true
"""

# After the envvars block, so the generated certificate is in place before any
# command runs — start, restart and configtest alike.
anchor = re.search(r"^if test -f .*?/bin/envvars; then\n.*?\nfi\n", text, re.MULTILINE | re.DOTALL)
if anchor:
    at = anchor.end()
else:                                 # no envvars here: right after the HTTPD line
    at = text.index("\n", match.end()) + 1
open(path, "w", encoding="utf-8").write(text[:at] + block + text[at:])
PYEOF

    if has_active "bin/vxost-ssl-init" "$PAYLOAD/bin/apachectl"; then
        echo "  apachectl: certificate generated on first start"
    else
        echo "!! apachectl has no certificate step: Apache would not start with -DSSL" >&2
        exit 1
    fi
fi

# my.cnf names temp/mysql as tmpdir. The folder lives under temp/, and anything
# under temp/ is fair game for deletion, so creating it once at build time is
# not enough: mysql.server makes sure it is there at every start. This is the
# same reasoning as apachectl above — one gate, every caller.
MYSQL_SERVER="$PAYLOAD/share/mysql/mysql.server"
if [ -f "$MYSQL_SERVER" ]; then
    python3 - "$MYSQL_SERVER" <<'PYEOF'
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8", errors="replace").read()

if "temp/mysql" in text:              # already patched
    sys.exit(0)

needle = '$bindir/mysqld_safe --datadir='
at = text.find(needle)
if at < 0:
    sys.stderr.write("!! mysql.server: no mysqld_safe call, cannot add the tmpdir step\n")
    sys.exit(1)

# mysqld_safe is started without saying which configuration to read, so mysqld
# falls back to the paths compiled into it — and those still say XAMPP. On a
# Mac that has XAMPP for real it reads XAMPP's my.cnf, and then announces
#
#   socket: '/Applications/XAMPP/xamppfiles/var/mysql/mysql.sock'
#   Can't open shared library '/Applications/XAMPP/.../plugin/auth_socket.so'
#
# while serving our data directory. Exactly the ServerRoot problem Apache had,
# in the other daemon. It cannot be seen on a machine where /Applications/XAMPP
# is the compatibility symlink, because there both names lead to the same file:
# it needs a Mac with a real XAMPP next door, which is the common case among
# the people migrating. Found on a customer Mac on 04/09/2026.
text = text.replace(needle, '$bindir/mysqld_safe --defaults-file="$basedir/etc/my.cnf" --datadir=', 1)
at = text.find('$bindir/mysqld_safe --defaults-file=')

line_start = text.rfind("\n", 0, at) + 1
indent = text[line_start:at].replace(text[line_start:at].strip(), "")

block = (
    f'{indent}# my.cnf points tmpdir at temp/mysql. Without it MariaDB stops\n'
    f'{indent}# before it can write its own error log, and a missing log looks\n'
    f'{indent}# like a missing datadir to whoever debugs it next.\n'
    f'{indent}if [ ! -d "$basedir/temp/mysql" ]; then\n'
    f'{indent}  mkdir -p "$basedir/temp/mysql"\n'
    f'{indent}  chmod 755 "$basedir/temp/mysql"\n'
    f'{indent}fi\n'
    f'{indent}# The package is installed by dragging it in the Finder, which\n'
    f'{indent}# gives every file to whoever dragged it. mysqld runs as mysql,\n'
    f'{indent}# so on a fresh install it cannot write anything in its own data\n'
    f'{indent}# directory — not even the log that would say so. What you see\n'
    f'{indent}# instead is "Starting MySQL...ok." and nothing listening on\n'
    f'{indent}# 3306. Seen on a customer Mac on 04/09/2026, after three days\n'
    f'{indent}# spent looking for a log that could never have been written.\n'
    f'{indent}# Ownership is fixed here rather than in the package because a\n'
    f'{indent}# DMG cannot carry it: the Finder rewrites it on copy.\n'
    f'{indent}_owner=`stat -f "%Su" "$datadir" 2>/dev/null`\n'
    f'{indent}case "$_owner" in\n'
    f'{indent}  mysql|_mysql) : ;;\n'
    f'{indent}  *) chown -R mysql "$datadir" 2>/dev/null || true ;;\n'
    f'{indent}esac\n'
    f'{indent}# ⚠️ La cartella temporanea si controlla per conto suo.\n'
    f'{indent}# Prima il suo chown era attaccato a quello del datadir: se il\n'
    f'{indent}# datadir era gia\' di mysql il ramo non scattava, e temp/mysql,\n'
    f'{indent}# appena creata qui sopra da root, restava di root. mysqld gira\n'
    f'{indent}# come mysql e non ci puo\' scrivere: tmpdir non scrivibile, e\n'
    f'{indent}# ogni tabella temporanea fallisce a partire dalla prima query\n'
    f'{indent}# un po\' grossa. Due cartelle diverse, due controlli diversi.\n'
    f'{indent}_tmpowner=`stat -f "%Su" "$basedir/temp/mysql" 2>/dev/null`\n'
    f'{indent}case "$_tmpowner" in\n'
    f'{indent}  mysql|_mysql) : ;;\n'
    f'{indent}  *) chown -R mysql "$basedir/temp/mysql" 2>/dev/null || true ;;\n'
    f'{indent}esac\n'
)
open(path, "w", encoding="utf-8").write(text[:line_start] + block + text[line_start:])
PYEOF

    if has_active 'mkdir -p "$basedir/temp/mysql"' "$MYSQL_SERVER"; then
        echo "  mysql.server: tmpdir created and ownership repaired before start"
    else
        echo "!! mysql.server has no tmpdir step: MariaDB would not start" >&2
        exit 1
    fi

    if has_active 'mysqld_safe --defaults-file=' "$MYSQL_SERVER"; then
        echo "  mysql.server: configuration passed explicitly"
    else
        echo "!! mysql.server was not patched: MariaDB would read XAMPP's my.cnf" >&2
        exit 1
    fi
fi

# The diagnose script announces one file and reads another: "Last 10 lines of
# logs/error_log", then tail on logs/error.log, which has never existed. A dot
# instead of an underscore, and the result is that the one moment it exists to
# be useful — Apache refused to start, here is why — it prints "No such file or
# directory" and nothing else. Seen for real on 21/08/2026, on top of a problem
# that was already hard enough to read.
if [ -f "$PAYLOAD/share/vxost/diagnose" ]; then
    sed -i '' 's|logs/error\.log|logs/error_log|g' "$PAYLOAD/share/vxost/diagnose"
    if has_active 'logs/error\.log' "$PAYLOAD/share/vxost/diagnose"; then
        echo "!! diagnose still points at logs/error.log" >&2
        exit 1
    fi
    echo "  diagnose: reads the log it names"
fi

# The syntax check in the control script calls httpd directly, so it needs the
# same two options. Without them it validates one file and starts another,
# which is worse than not checking at all: it reports Syntax OK for a config
# that is not the one about to be used.
if [ -f "$PAYLOAD/vxost" ]; then
    perl -pi -e 's|\$VXOST_ROOT/bin/httpd -t \$apachedefines|\$VXOST_ROOT/bin/httpd -t -d "\$VXOST_ROOT" -f "\$VXOST_ROOT/etc/httpd.conf" \$apachedefines|' \
        "$PAYLOAD/vxost"

    # ⛔ E qui sta il difetto che e' costato piu' di ogni altro: lo script
    # annuncia "ok." su avvii che non sono avvenuti e su arresti che non hanno
    # fermato niente.
    #
    #   $VXOST_ROOT/bin/mysql.server start > /dev/null &
    #   if test $? -ne 0
    #
    # Il comando e' in background: quel $? e' l'esito del *lancio*, sempre
    # zero. Il 05/09/2026, sul Mac di un cliente, MariaDB ha stampato "ok." e
    # trentadue secondi dopo e' morta su un lock; per quattro giorni ogni
    # tentativo di diagnosi e' partito dal presupposto che fosse avviata.
    #
    # E il controllo che avrebbe dovuto accorgersi dell'istanza gia' viva
    # guardava la porta 3308, mentre MariaDB sta sulla 3306: non ha mai
    # protetto nessuno.
    #
    # ⛔ Un messaggio di esito che non verifica l'esito e' peggio del silenzio:
    # manda a cercare la causa ovunque tranne dove sta.
    python3 - "$PAYLOAD/vxost" <<'PYEOF'
import re, sys

path = sys.argv[1]
text = open(path, encoding="utf-8", errors="replace").read()
prima = text

# 0. Il certificato, prima del controllo di sintassi.
#
# ⛔ Senza questo, tutto il resto non serve. startApache() aggiunge -DSSL
# quando trova etc/vxost/startssl, che nel pacchetto c'e' sempre perche'
# arriva da upstream. Con -DSSL httpd -t si ferma su
#
#   SSLCertificateFile: file 'etc/ssl.crt/server.crt' does not exist
#
# e la funzione torna 1 tre righe prima di arrivare ad apachectl, che e' dove
# il certificato verrebbe generato. Su un Mac che non ha mai avuto XAMPP,
# Apache non parte affatto: il rimedio sta dietro la porta che non si apre.
ancora_ssl = "\tsyntaxCheckMessage=$("
if ancora_ssl not in text:
    sys.stderr.write("!! vxost: startApache non ha la forma attesa, non lo tocco\n")
    sys.exit(1)
if "vxost-ssl-init" not in text:
    text = text.replace(ancora_ssl, (
        "\t# Il certificato di questa macchina, se manca. Deve stare prima del\n"
        "\t# controllo di sintassi: con -DSSL, httpd -t senza certificato\n"
        "\t# fallisce e apachectl non viene raggiunto mai.\n"
        "\tif test $ssl -eq 1\n"
        "\tthen\n"
        "\t\t\"$VXOST_ROOT/bin/vxost-ssl-init\" || true\n"
        "\tfi\n"
        "\n"
    ) + ancora_ssl, 1)

# 1. La porta sbagliata. MariaDB ascolta sulla 3306, e my.cnf lo conferma.
text = text.replace("if testport 3308", "if testport 3306", 1)

# 2. L'avvio: si aspetta che la porta risponda davvero prima di dire ok.
#    Sessanta secondi perche' un recovery InnoDB dopo un arresto brusco ci
#    mette molto piu' dei pochi secondi che uno si aspetta.
avvio_vecchio = re.search(
    r"([ \t]*)\$VXOST_ROOT/bin/mysql\.server start > /dev/null &\s*\n"
    r".*?\n[ \t]*\$GETTEXT -s \"ok\.\"\s*\n[ \t]*return 0\s*\n",
    text, re.DOTALL)
# ⚠️ Tre esiti, non due.
#
# SOURCE e' /Applications/VXOST/vxostfiles quando c'e', cioe' l'installazione
# gia' fatta con un pacchetto precedente: il suo script e' gia' patchato, la
# forma vecchia non esiste piu', e questo ramo faceva uscire 1. Con
# set -euo pipefail la ricostruzione del pacchetto si fermava, dicendo "non ha
# la forma attesa" di uno script che aveva esattamente la forma giusta.
#
# Applicata / gia' applicata / incompatibile sono tre cose diverse, e solo la
# terza e' un errore.
if not avvio_vecchio:
    if "atteso -lt 60" in text and "testport 3306" in text:
        print("  vxost: startMySQL gia' patchato, lasciato com'e'")
    else:
        sys.stderr.write("!! vxost: startMySQL non ha la forma attesa, non lo tocco\n")
        sys.exit(1)
else:

    avvio_nuovo = '''\t$VXOST_ROOT/bin/mysql.server start > /dev/null 2>&1 &

\t# Il comando e' in background: il suo codice di uscita non dice niente.
\t# L'unica prova che MariaDB e' partita e' che risponda sulla sua porta.
\tatteso=0
\twhile test $atteso -lt 60
\tdo
\t\tif testport 3306
\t\tthen
\t\t\t$GETTEXT -s "ok."
\t\t\treturn 0
\t\tfi
\t\tsleep 1
\t\tatteso=$((atteso + 1))
\tdone

\t$GETTEXT -s "fail."

\t# Il log porta il nome della macchina, e quel nome puo' non combaciare:
\t# se non c'e', si prende il piu' recente invece di tacere.
\tmysqllog="$VXOST_ROOT/var/mysql/$(hostname).err"
\ttest -f "$mysqllog" || mysqllog="$(ls -t "$VXOST_ROOT/var/mysql/"*.err 2>/dev/null | head -1)"
\tif test -n "$mysqllog" && test -f "$mysqllog"
\tthen
\t\tprintf "$($GETTEXT -s 'Last 10 lines of \\"%s\\":')\\n" "$mysqllog"
\t\ttail -n 10 "$mysqllog"
\tfi
\treturn 1
'''
    text = text[:avvio_vecchio.start()] + avvio_nuovo + text[avvio_vecchio.end():]

# 3. L'arresto: "ok." solo quando la porta e' libera davvero.
# 3b. Il ramo che dichiara MySQL fermo senza guardare se lo e'.
#
# ⚠️ Il file pid porta il nome della macchina: var/mysql/$(hostname).pid. Quel
# nome cambia quando si rinomina il Mac, quando si passa da una rete che
# assegna il nome DHCP a un'altra, o semplicemente se qualcuno ha cancellato
# il file. In tutti quei casi MariaDB sta girando e la funzione rispondeva
# "not running." tornando 0: l'app la crede ferma, il pulsante di avvio
# riparte, e l'errore che si vede alla fine parla di una porta occupata da
# nessuno. Si guarda anche la porta prima di dirlo.
non_gira = re.search(
    r'\tif ! test -f "\$VXOST_ROOT/var/mysql/\$\(hostname\)\.pid"\n'
    r'\tthen\n\t\t\$GETTEXT -s "not running\."\n\t\treturn 0\n\tfi\n',
    text)
if non_gira and "testport 3306" not in text[non_gira.start():non_gira.end()]:
    text = (text[:non_gira.start()] +
            '\t# Il file pid porta il nome della macchina, e quel nome puo\' non\n'
            '\t# combaciare piu\'. Fermo vuol dire che la porta non risponde.\n'
            '\tif ! test -f "$VXOST_ROOT/var/mysql/$(hostname).pid" && ! testport 3306\n'
            '\tthen\n\t\t$GETTEXT -s "not running."\n\t\treturn 0\n\tfi\n' +
            text[non_gira.end():])

arresto_vecchio = re.search(
    r"([ \t]*)\$VXOST_ROOT/bin/mysql\.server stop > /dev/null 2>&1\s*\n"
    r"[ \t]*error=\$\?\s*\n"
    r".*?\n[ \t]*\$GETTEXT -s \"ok\.\"\s*\n[ \t]*return 0\s*\n",
    text, re.DOTALL)
if not arresto_vecchio:
    if "MySQL is still listening" in text:
        print("  vxost: stopMySQL gia' patchato, lasciato com'e'")
    else:
        sys.stderr.write("!! vxost: stopMySQL non ha la forma attesa, non lo tocco\n")
        sys.exit(1)
else:

    arresto_nuovo = '''\t$VXOST_ROOT/bin/mysql.server stop > /dev/null 2>&1

\t# mysql.server torna con successo anche quando ha mandato il segnale a un
\t# pid gia' morto. Fermo vuol dire che la porta non risponde piu'.
\tatteso=0
\twhile test $atteso -lt 30
\tdo
\t\tif testport 3306
\t\tthen
\t\t\tsleep 1
\t\t\tatteso=$((atteso + 1))
\t\telse
\t\t\t$GETTEXT -s "ok."
\t\t\treturn 0
\t\tfi
\tdone

\t$GETTEXT -s "fail."
\techo "VXOST: " $($GETTEXT 'MySQL is still listening on port 3306.')
\treturn 1
'''
    text = text[:arresto_vecchio.start()] + arresto_nuovo + text[arresto_vecchio.end():]

# 4. proftpd riceve la propria configurazione: quella compilata dentro punta
#    ancora al vecchio nome, e con -c non viene nemmeno guardata.
text = text.replace(
    "$VXOST_ROOT/sbin/proftpd > $VXOST_ROOT/var/proftpd/start.err 2>&1",
    '$VXOST_ROOT/sbin/proftpd -c "$VXOST_ROOT/etc/proftpd.conf" > $VXOST_ROOT/var/proftpd/start.err 2>&1',
    1)

# 5. stopApache() e stopProFTPD() (rilievo M): "not running" dedotto dalla
#    sola assenza del file pid, e "ok." appena il comando usciva, senza
#    guardare se il processo c'era ancora. Un file pid manca anche con Apache
#    su, e c'e' anche con Apache giu' da giorni; e kill che torna 0 vuol dire
#    "segnale consegnato", non "fermo". Le funzioni nuove distinguono quattro
#    esiti: file pid assente, processo assente (pid vecchio o riciclato, che
#    NON si segnala: potrebbe essere l'Apache di sistema o un altro
#    programma), segnale mandato, arresto verificato aspettando che il
#    processo sparisca. Il pid vale solo se il suo eseguibile sta sotto
#    $VXOST_ROOT: un pid riciclato da /usr/sbin/httpd non e' nostro.
# I due aiutanti che le funzioni di arresto usano. Inseriti una volta sola,
# prima di startProFTPD, che e' la prima funzione di servizio del file.
#
# ⚠️ `case "$cmd" in "$VXOST_ROOT"/*httpd)` accettava anche
# $VXOST_ROOT/bin/nothttpd: l'asterisco copre le barre e qualunque prefisso.
# Il nome si confronta per basename esatto, e il percorso deve stare sotto la
# nostra radice. Sono due condizioni, non un motivo solo.
AIUTANTI = '''
# --- aggiunti da VXOST: identificare i propri processi ---------------------

# Vero se $1 e' un processo vivo il cui eseguibile e' $VXOST_ROOT/.../$2.
function vxostProcessIsOurs() {
\tvxpid="$1"
\tvxname="$2"
\ttest -n "$vxpid" || return 1
\tkill -0 "$vxpid" 2>/dev/null || return 1
\tvxcmd=$(ps -p "$vxpid" -o comm= 2>/dev/null)
\ttest -n "$vxcmd" || return 1
\t# Basename esatto: "nothttpd" non e' "httpd".
\ttest "${vxcmd##*/}" = "$vxname" || return 1
\tcase "$vxcmd" in
\t\t"$VXOST_ROOT"/*) return 0 ;;
\tesac
\treturn 1
}

# I pid dei nostri processi di nome $1, senza passare dal file pid. Esce 1 se
# non si riesce nemmeno a elencare i processi: non sapere e' diverso da sapere
# che non ce ne sono.
function vxostOurPids() {
\tvxname="$1"
\tcommand -v pgrep > /dev/null 2>&1 || return 1
\tfor vxp in $(pgrep -f "$VXOST_ROOT" 2>/dev/null)
\tdo
\t\tif vxostProcessIsOurs "$vxp" "$vxname"
\t\tthen
\t\t\techo "$vxp"
\t\tfi
\tdone
\treturn 0
}

'''

if "vxostProcessIsOurs" not in text:
    inizio = text.find("function startProFTPD() {")
    if inizio < 0:
        sys.stderr.write("!! vxost: startProFTPD non trovata, non so dove mettere gli aiutanti\n")
        sys.exit(1)
    text = text[:inizio] + AIUTANTI + text[inizio:]
else:
    print("  vxost: aiutanti gia' presenti")


def sostituisci_funzione(text, nome, corpo, marcatore):
    m = re.search(r"function " + nome + r"\(\) \{\n.*?\n\}\n", text, re.S)
    if not m:
        sys.stderr.write("!! vxost: " + nome + " non trovata, non la tocco\n")
        sys.exit(1)
    if marcatore in m.group(0):
        print("  vxost: " + nome + " gia' patchata, lasciata com'e'")
        return text
    return text[:m.start()] + corpo + text[m.end():]

stop_apache = '''function stopApache() {
	
	printf "VXOST: $($GETTEXT 'Stopping %s...')" "Apache"

	# Quattro esiti, non due: fermo davvero, segnale mandato e verificato,
	# fallito, e "non lo so". L'ultimo esisteva e veniva riportato come
	# successo: senza file pid la funzione diceva "not running." e usciva 0
	# mentre Apache serviva le pagine. Il file pid manca ogni volta che e'
	# stato cancellato a mano, che il processo e' partito altrove, o che la
	# cartella logs e' stata svuotata.
	pid=""
	pidfile="$VXOST_ROOT/logs/httpd.pid"
	if test -f "$pidfile"
	then
		candidato=$(tr -d ' \\n' < "$pidfile" 2>/dev/null)
		if vxostProcessIsOurs "$candidato" httpd
		then
			pid="$candidato"
		else
			# Vecchio, o riciclato da un altro programma: non dice niente,
			# e non si segnala nessuno sulla sua parola.
			rm -f "$pidfile"
		fi
	fi

	if test -z "$pid"
	then
		if ! elenco=$(vxostOurPids httpd)
		then
			$GETTEXT -s "unverified."
			echo "VXOST: " $($GETTEXT 'No usable pid file and no way to list processes: whether Apache is running is unknown.')
			return 1
		fi
		pid=$(echo "$elenco" | head -1)
	fi

	if test -z "$pid"
	then
		$GETTEXT -s "not running."
		return 0
	fi

	if test -f $lc/startssl
	then
		apachedefines="$apachedefines -DSSL"
	fi
	apachedefines="$apachedefines -DPHP"

	# apachectl puo' uscire in errore prima di segnalare: il suo esito si
	# tiene per il messaggio, l'arresto si verifica sul processo.
	$VXOST_ROOT/bin/apachectl -k stop $apachedefines > /dev/null 2>&1
	ctl=$?
	kill -0 "$pid" 2>/dev/null && kill -TERM "$pid" 2>/dev/null

	atteso=0
	while test $atteso -lt 20 && kill -0 "$pid" 2>/dev/null
	do
		sleep 1
		atteso=$((atteso + 1))
	done

	if kill -0 "$pid" 2>/dev/null
	then
		$GETTEXT -s "fail."
		echo "httpd (pid $pid) is still running after 20 seconds (apachectl returned $ctl)."
		return 1
	fi

	$GETTEXT -s "ok."
	return 0
}
'''

stop_proftpd = '''function stopProFTPD() {
	
	printf "VXOST: $($GETTEXT 'Stopping %s...')" "ProFTPD"

	pid=""
	pidfile="$VXOST_ROOT/var/proftpd.pid"
	if test -f "$pidfile"
	then
		candidato=$(tr -d ' \\n' < "$pidfile" 2>/dev/null)
		if vxostProcessIsOurs "$candidato" proftpd
		then
			pid="$candidato"
		else
			rm -f "$pidfile"
		fi
	fi

	if test -z "$pid"
	then
		if ! elenco=$(vxostOurPids proftpd)
		then
			$GETTEXT -s "unverified."
			echo "VXOST: " $($GETTEXT 'No usable pid file and no way to list processes: whether ProFTPD is running is unknown.')
			return 1
		fi
		pid=$(echo "$elenco" | head -1)
	fi

	if test -z "$pid"
	then
		$GETTEXT -s "not running."
		return 0
	fi

	# kill che torna 0 vuol dire "segnale consegnato", non "fermo".
	if ! kill -TERM "$pid" 2>/dev/null
	then
		$GETTEXT -s "fail."
		echo "could not signal proftpd (pid $pid)."
		return 1
	fi

	atteso=0
	while test $atteso -lt 15 && kill -0 "$pid" 2>/dev/null
	do
		sleep 1
		atteso=$((atteso + 1))
	done

	if kill -0 "$pid" 2>/dev/null
	then
		$GETTEXT -s "fail."
		echo "proftpd (pid $pid) is still running after 15 seconds."
		return 1
	fi

	$GETTEXT -s "ok."
	return 0
}
'''

text = sostituisci_funzione(text, "stopApache", stop_apache, "vxostProcessIsOurs")
text = sostituisci_funzione(text, "stopProFTPD", stop_proftpd, "vxostProcessIsOurs")

if text == prima:
    # Niente da cambiare perche' era gia' tutto a posto: si esce bene. Era un
    # errore, e bastava ricostruire il pacchetto due volte di fila per vederlo.
    print("  vxost: nessuna modifica necessaria, era gia' tutto applicato")
    sys.exit(0)
open(path, "w", encoding="utf-8").write(text)
PYEOF

    # ⚠️ Nessun '$' nelle stringhe cercate: fra le virgolette la shell lo
    # espanderebbe, il grep cercherebbe una riga che non esiste e il controllo
    # direbbe di no su una patch entrata benissimo. Verificato: e' successo.
    for _atteso in "testport 3306" "atteso -lt 60" "MySQL is still listening" "proftpd -c" "vxost-ssl-init" "vxostProcessIsOurs" "vxostOurPids" "is unknown" "still running after 20 seconds"; do
        has_active "$_atteso" "$PAYLOAD/vxost" || {
            echo "!! vxost was not patched: '$_atteso' is missing" >&2
            exit 1
        }
    done
    echo "  vxost: start and stop now check before saying ok"

    if ! bash -n "$PAYLOAD/vxost"; then
        echo "!! the patched vxost is not valid shell" >&2
        exit 1
    fi
fi

# MySQL must listen on TCP: a "security check" run once can leave this on and
# every project connecting to 127.0.0.1:3306 then breaks.
if [ -f "$PAYLOAD/etc/my.cnf" ]; then
    # ⚠️ Anche indentato. Una direttiva preceduta da spazi resta attiva, e la
    # vecchia espressione, ancorata a inizio riga, la lasciava passare.
    sed -i '' -E 's/^([[:space:]]*)skip-networking/\1#skip-networking/' "$PAYLOAD/etc/my.cnf"

    # It must listen on loopback only, though. Without bind-address MariaDB
    # answers on every interface, so anyone on the same wifi can reach the
    # database of a machine that was only meant to serve itself. This is the
    # protection the old security check was reaching for when it reached for
    # skip-networking instead and broke every project on the machine.
    #
    # ⛔ Una bind-address che c'e' gia' si riscrive, non si rispetta.
    #
    # Prima il blocco veniva saltato appena ne trovava una qualsiasi, e
    # "qualsiasi" comprende bind-address=0.0.0.0, cioe' l'opposto di quello
    # che serve: il pacchetto sarebbe uscito con il database raggiungibile da
    # tutta la rete, e il controllo qui sopra avrebbe stampato che era tutto
    # a posto proprio perche' la riga c'era.
    if grep -qE '^[[:space:]]*bind-address' "$PAYLOAD/etc/my.cnf"; then
        sed -i '' -E 's/^([[:space:]]*)bind-address[[:space:]]*=.*/\1bind-address=127.0.0.1/' \
            "$PAYLOAD/etc/my.cnf"
        printf "  MySQL bind-address rewritten to 127.0.0.1\n"
    else
        perl -pi -e 'if (/^\[mysqld\]/ && !$done) {
            $_ .= "\n# Reachable from this computer only. Do not replace this with\n";
            $_ .= "# skip-networking, which would cut off every project that\n";
            $_ .= "# connects to 127.0.0.1:3306.\n";
            $_ .= "bind-address=127.0.0.1\n";
            $done = 1;
        }' "$PAYLOAD/etc/my.cnf"
        printf "  MySQL restricted to 127.0.0.1\n"
    fi

    # La postcondizione: senza [mysqld] il perl non avrebbe inserito niente e
    # non lo avrebbe detto. Una direttiva che si crede scritta e non c'e' e'
    # peggio di una che manca e basta.
    if ! grep -qE '^[[:space:]]*bind-address[[:space:]]*=[[:space:]]*127\.0\.0\.1' \
            "$PAYLOAD/etc/my.cnf"; then
        echo "!! my.cnf has no active bind-address=127.0.0.1: the database would" >&2
        echo "   answer on every interface of the machine that installs it" >&2
        exit 1
    fi
    if grep -qE '^[[:space:]]*skip-networking' "$PAYLOAD/etc/my.cnf"; then
        echo "!! my.cnf still has an active skip-networking: every project that" >&2
        echo "   connects to 127.0.0.1:3306 would stop working" >&2
        exit 1
    fi
fi

# ---------------------------------------------------------------- database ---

# ------------------------------------------------------------- esposizione ---
#
# Tre cose che il pacchetto apriva o diceva senza che nessuno l'avesse chiesto
# (rilievi S, V e W della revisione del 10/09):
#
#   - ProFTPD ascoltava su tutte le interfacce (*.21) mentre Apache e MariaDB
#     stavano su 127.0.0.1. Il selettore dell'app riscrive le Listen di
#     Apache e basta: "solo questo Mac" non chiudeva FTP. Ora FTP nasce su
#     loopback, e per aprirlo si modifica proftpd.conf a mano.
#   - ServerTokens Full e expose_php=On stampavano "Apache/2.4.56 (Unix)
#     OpenSSL/1.1.1t PHP/8.2.4" in ogni pagina di errore e in ogni risposta:
#     meta' del lavoro di chi cerca falle note, regalata.
#   - error/include/bottom.html stampa SERVER_SOFTWARE via SSI in tutte le
#     pagine di errore multilingua. Con ServerTokens Prod dice solo "Apache",
#     ma la riga non serve a nessuno e resta una spia pronta se qualcuno
#     riapre i token.
#
# Stesso schema del bind-address di MariaDB qui sopra: quello che c'e' si
# riscrive, quello che manca si aggiunge, e si verifica sulle righe attive.
step "Keeping FTP, versions and error pages quiet"
if [ -f "$PAYLOAD/etc/proftpd.conf" ]; then
    if grep -qE '^[[:space:]]*DefaultAddress[[:space:]]' "$PAYLOAD/etc/proftpd.conf"; then
        sed -i '' -E 's/^([[:space:]]*)DefaultAddress[[:space:]].*/\1DefaultAddress 127.0.0.1/' \
            "$PAYLOAD/etc/proftpd.conf"
        echo "  proftpd: DefaultAddress rewritten to 127.0.0.1"
    else
        perl -pi -e 'if (/^Port\s+\d+/ && !$done) {
            $_ .= "\n# Reachable from this computer only. The exposure selector in the VXOST\n";
            $_ .= "# app rewrites the Apache Listen lines, not this file: FTP stays on\n";
            $_ .= "# loopback whatever is chosen there. To reach it from the local network,\n";
            $_ .= "# change DefaultAddress by hand and restart ProFTPD.\n";
            $_ .= "DefaultAddress 127.0.0.1\n";
            $done = 1;
        }' "$PAYLOAD/etc/proftpd.conf"
        echo "  proftpd: restricted to 127.0.0.1"
    fi
    # Senza SocketBindTight proftpd ascolta comunque su tutte le interfacce e
    # usa DefaultAddress solo per scegliere il server virtuale.
    if grep -qE '^[[:space:]]*SocketBindTight[[:space:]]' "$PAYLOAD/etc/proftpd.conf"; then
        sed -i '' -E 's/^([[:space:]]*)SocketBindTight[[:space:]].*/\1SocketBindTight on/' \
            "$PAYLOAD/etc/proftpd.conf"
    else
        printf '# Bind to DefaultAddress only, not to every interface.\nSocketBindTight on\n' \
            >> "$PAYLOAD/etc/proftpd.conf"
    fi
    if ! grep -qE '^[[:space:]]*DefaultAddress[[:space:]]+127\.0\.0\.1[[:space:]]*$' "$PAYLOAD/etc/proftpd.conf" \
       || ! grep -qE '^[[:space:]]*SocketBindTight[[:space:]]+on[[:space:]]*$' "$PAYLOAD/etc/proftpd.conf"; then
        echo "!! proftpd.conf: FTP would answer on every interface of the machine" >&2
        exit 1
    fi
fi

DEFAULTS="$PAYLOAD/etc/extra/httpd-default.conf"
if [ -f "$DEFAULTS" ]; then
    for _wanted in "ServerTokens Prod" "ServerSignature Off"; do
        _name=${_wanted%% *}; _value=${_wanted#* }
        if grep -qE "^[[:space:]]*$_name[[:space:]]" "$DEFAULTS"; then
            sed -i '' -E "s/^([[:space:]]*)$_name[[:space:]].*/\1$_name $_value/" "$DEFAULTS"
        else
            printf '\n%s %s\n' "$_name" "$_value" >> "$DEFAULTS"
        fi
        if ! grep -qE "^[[:space:]]*$_name[[:space:]]+$_value[[:space:]]*$" "$DEFAULTS"; then
            echo "!! httpd-default.conf: '$_wanted' is not active" >&2
            exit 1
        fi
    done
    echo "  httpd-default.conf: ServerTokens Prod, ServerSignature Off"
fi

if [ -f "$PAYLOAD/etc/php.ini" ]; then
    if grep -qE '^[[:space:]]*expose_php[[:space:]]*=' "$PAYLOAD/etc/php.ini"; then
        sed -i '' -E 's/^([[:space:]]*)expose_php[[:space:]]*=.*/\1expose_php=Off/' "$PAYLOAD/etc/php.ini"
    else
        printf '\n; The PHP version is not announced in the response headers.\nexpose_php=Off\n' \
            >> "$PAYLOAD/etc/php.ini"
    fi
    if ! grep -qE '^[[:space:]]*expose_php[[:space:]]*=[[:space:]]*Off[[:space:]]*$' "$PAYLOAD/etc/php.ini"; then
        echo "!! php.ini: expose_php is not Off" >&2
        exit 1
    fi
    echo "  php.ini: expose_php=Off"
fi

if [ -f "$PAYLOAD/error/include/bottom.html" ] && grep -q 'SERVER_SOFTWARE' "$PAYLOAD/error/include/bottom.html"; then
    sed -i '' '/SERVER_SOFTWARE/d' "$PAYLOAD/error/include/bottom.html"
    echo "  error pages: the SERVER_SOFTWARE line is gone"
fi
if [ -d "$PAYLOAD/error" ] && grep -rq 'SERVER_SOFTWARE' "$PAYLOAD/error"; then
    echo "!! error/: a page still prints SERVER_SOFTWARE" >&2
    exit 1
fi

step "Creating an empty database"
# Not copied: InnoDB stores every table in ibdata1, so copying the folder while
# excluding database directories would still carry the data.
#
# An isolated defaults file is essential: without it the installer reads the
# system my.cnf, points at the real data directory and fails on a ibdata1 it
# cannot write, or worse, touches the live database.
mkdir -p "$PAYLOAD/var/mysql"
cat > "$STAGE/init-my.cnf" <<CNF
[mysqld]
basedir=$PAYLOAD
datadir=$PAYLOAD/var/mysql
socket=$PAYLOAD/var/mysql/mysql.sock
CNF

"$PAYLOAD/bin/mysql_install_db" \
    --defaults-file="$STAGE/init-my.cnf" \
    --basedir="$PAYLOAD" \
    --datadir="$PAYLOAD/var/mysql" > /dev/null 2>&1 || {
        echo "  mysql_install_db failed" >&2; exit 1; }

printf "  removing the build machine's accounts and traces\n"

cat > "$STAGE/db-init.sql" <<'SQL'
DROP USER IF EXISTS 'BUILDUSER'@'localhost';
DROP USER IF EXISTS ''@'BUILDHOST';
DROP USER IF EXISTS ''@'localhost';
-- Dropping the account leaves the hostname inside the Aria table file until
-- the table is emptied and rewritten, so it is cleared explicitly.
TRUNCATE TABLE mysql.proxies_priv;
ALTER USER 'root'@'localhost' IDENTIFIED VIA mysql_native_password USING PASSWORD('root');
CREATE USER IF NOT EXISTS 'root'@'127.0.0.1' IDENTIFIED VIA mysql_native_password USING PASSWORD('root');
GRANT ALL PRIVILEGES ON *.* TO 'root'@'127.0.0.1' WITH GRANT OPTION;
CREATE USER IF NOT EXISTS 'root'@'::1' IDENTIFIED VIA mysql_native_password USING PASSWORD('root');
GRANT ALL PRIVILEGES ON *.* TO 'root'@'::1' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL
sed -i '' "s/BUILDUSER/$(whoami)/; s/BUILDHOST/$(hostname | tr '[:upper:]' '[:lower:]')/" "$STAGE/db-init.sql"

# ⚠️ Niente attese a occhio, e nessun esito buttato via.
#
# Prima erano `sleep 8`, poi un `mysql -e ... || true`: su una macchina lenta,
# o con un antivirus di mezzo, il server non era ancora pronto e il comando
# falliva in silenzio. Il pacchetto usciva lo stesso, con la password di root
# non impostata — mentre il sito documenta root/root — e con l'hostname della
# macchina che lo aveva costruito ancora dentro le tabelle dei privilegi.
# Nessuno se ne accorgeva finche' qualcuno non provava ad accedere.
"$PAYLOAD/sbin/mysqld" --defaults-file="$STAGE/init-my.cnf" \
    --init-file="$STAGE/db-init.sql" --skip-networking > "$STAGE/mysqld-init.log" 2>&1 &
_mysqld_pid=$!

_socket="$PAYLOAD/var/mysql/mysql.sock"
_atteso=0
while [ $_atteso -lt 60 ] && [ ! -S "$_socket" ]; do
    sleep 1
    _atteso=$((_atteso + 1))
done
if [ ! -S "$_socket" ]; then
    echo "!! mysqld never opened its socket: the database would ship uninitialised" >&2
    tail -10 "$STAGE/mysqld-init.log" >&2
    kill "$_mysqld_pid" 2>/dev/null || true
    exit 1
fi

# La prova che l'init-file e' passato davvero: se root/root non entra, tutto
# quello che viene dopo lavora su un database che non e' quello che credevamo.
if ! "$PAYLOAD/bin/mysql" --socket="$_socket" -u root -proot \
        -e "SELECT 1" > /dev/null 2>&1; then
    echo "!! root/root does not work: the init file did not run" >&2
    tail -10 "$STAGE/mysqld-init.log" >&2
    "$PAYLOAD/bin/mysqladmin" --socket="$_socket" -u root -proot shutdown >/dev/null 2>&1 || \
        kill "$_mysqld_pid" 2>/dev/null || true
    exit 1
fi
echo "  root account ready"

# Dropping the accounts is not enough: the hostname survives in the Aria
# transaction logs and inside the privilege tables until they are rebuilt.
printf "  rebuilding privilege tables\n"
if ! "$PAYLOAD/bin/mysql" --socket="$_socket" -u root -proot -e "
    INSERT INTO mysql.proxies_priv (Host, User, Proxied_host, Proxied_user, With_grant)
        VALUES ('localhost','root','','',1)
        ON DUPLICATE KEY UPDATE With_grant=1;
    OPTIMIZE TABLE mysql.proxies_priv, mysql.global_priv, mysql.db,
                   mysql.tables_priv, mysql.columns_priv, mysql.procs_priv;
    FLUSH PRIVILEGES;" > "$STAGE/priv-rebuild.log" 2>&1; then
    echo "!! the privilege tables were not rebuilt: the build machine's hostname" >&2
    echo "   would ship inside them" >&2
    tail -5 "$STAGE/priv-rebuild.log" >&2
    exit 1
fi

"$PAYLOAD/bin/mysqladmin" --socket="$_socket" \
    -u root -proot shutdown > /dev/null 2>&1 || true

# ⛔ Si aspetta che il processo sia uscito davvero prima di toccare i log di
# Aria. Cancellarli mentre mysqld e' ancora vivo vuol dire togliergli il
# giornale delle transazioni da sotto i piedi, e il datadir che finisce nel
# pacchetto e' quello che ne esce.
_atteso=0
while [ $_atteso -lt 60 ] && kill -0 "$_mysqld_pid" 2>/dev/null; do
    sleep 1
    _atteso=$((_atteso + 1))
done
if kill -0 "$_mysqld_pid" 2>/dev/null; then
    echo "  shutdown ignored, asking again"
    kill -TERM "$_mysqld_pid" 2>/dev/null || true
    _atteso=0
    while [ $_atteso -lt 30 ] && kill -0 "$_mysqld_pid" 2>/dev/null; do
        sleep 1
        _atteso=$((_atteso + 1))
    done
fi
if kill -0 "$_mysqld_pid" 2>/dev/null; then
    echo "!! mysqld is still running: the Aria logs must not be removed under it" >&2
    exit 1
fi
echo "  database stopped cleanly"

# ⚠️ I file di lavoro di questo passo si tolgono adesso. Restano nella radice
# dello staging, quindi non entrano nel disco (il DMG copia vxostfiles e
# VXOST.app e basta), ma contengono il percorso della home di chi costruisce
# e la password di root in chiaro, e una cartella di lavoro con dentro quelle
# due cose e' il posto sbagliato dove lasciarle. Il 11/09/2026 il controllo
# finale si e' fermato proprio su mysqld-init.log.
rm -f "$STAGE/mysqld-init.log" "$STAGE/priv-rebuild.log" \
      "$STAGE/db-init.sql" "$STAGE/init-my.cnf"

# Transaction logs are regenerated on first start and carry the old hostname.
rm -f "$PAYLOAD/var/mysql/aria_log."* "$PAYLOAD/var/mysql/aria_log_control" \
      "$PAYLOAD/var/mysql/"*.err "$PAYLOAD/var/mysql/"*.pid \
      "$PAYLOAD/var/mysql/"*.sock "$PAYLOAD/var/mysql/multi-master.info" 2>/dev/null || true
rm -f "$STAGE/db-init.sql" "$STAGE/init-my.cnf"

# --------------------------------------------------------------- the app ---

# 🔴 I binari si firmano, o macOS li uccide sul Mac di chi scarica.
#
# Arrivano dall'installer del 2018 e non sono firmati affatto: "code object is
# not signed at all". Sulla macchina che li ha installati funzionano, perche'
# quei file non hanno l'attributo di quarantena. Ma un DMG scaricato da
# internet ce l'ha, e si propaga a tutto quello che si estrae: Gatekeeper li
# ferma con SIGKILL, e nel Terminale si legge soltanto
#
#     Killed: 9
#
# Nient'altro. Non dice che e' Gatekeeper, non dice che e' la quarantena, non
# dice cosa fare. Chi ha scaricato pensa che il pacchetto sia rotto.
#
# ⚠️ La firma ad-hoc non e' una notarizzazione e non fa sparire l'avviso al
# primo avvio dell'app: quello serve un account Apple. Ma toglie di mezzo il
# caso peggiore, il binario che muore senza spiegazioni, e rende la quarantena
# una cosa che si toglie una volta invece che un muro.
# ------------------------------------------------------- the old name inside ---

step "Cutting the last tie to the old name"
# Questo script non compila niente: copia uno stack gia' installato, lo
# rimarchia e lo impacchetta. I binari restano quelli dell'installer del 2018,
# e dentro ogni Mach-O l'install name delle librerie e' un percorso assoluto
# che dice ancora XAMPP:
#
#   $ otool -L bin/httpd
#     /Applications/XAMPP/xamppfiles/lib/libpcre.1.dylib
#
# Misurato sul DMG 9.26.1: 190 binari su 313 e 55 librerie su 60. Finche' quei
# percorsi restano, VXOST non sta in piedi da solo — regge solo grazie al
# symlink /Applications/XAMPP creato dalla migrazione. Su un Mac dove quel
# percorso non esiste, dyld ferma tutto con "Library not loaded" e i comandi
# muoiono con Abort trap: 6. E' successo il 05/09/2026 sul Mac di un cliente
# che aveva rinominato XAMPP: MariaDB ha smesso di partire all'istante.
#
# Si riscrivono qui, una volta, per tutti quelli che scaricheranno il
# pacchetto: nessun utente deve lanciare niente, e nessuna installazione ha
# piu' bisogno di quel symlink. Prima della firma, perche' install_name_tool
# invalida la firma di quello che tocca.
#
# ⚠️ Serve il percorso di INSTALLAZIONE, non quello di build: i binari devono
# puntare a dove finiranno, non allo staging. Si legge dal ServerRoot che il
# branding ha gia' scritto, invece di ripeterlo qui: un percorso scritto a
# mano in due punti e' un percorso che prima o poi diverge.
NUOVA_RADICE="$(grep -m1 -E '^\s*ServerRoot' "$PAYLOAD/etc/httpd.conf" 2>/dev/null | sed -E 's/.*"(.*)".*/\1/')"
if [ -z "$NUOVA_RADICE" ]; then
    echo "!! no ServerRoot in httpd.conf: cannot tell where the binaries will live" >&2
    exit 1
fi
VECCHIA_RADICE="/Applications/XAMPP/xamppfiles"
echo "  $VECCHIA_RADICE -> $NUOVA_RADICE"

# ⚠️ I due prefissi sono lunghi uguali, 30 caratteri, e non e' un caso: e' la
# ragione per cui questa operazione e' sicura. install_name_tool riscrive in
# loco senza riallocare i load command, che e' il modo classico in cui questo
# strumento corrompe un binario.
if [ ${#VECCHIA_RADICE} -ne ${#NUOVA_RADICE} ]; then
    echo "!! the two paths have different lengths (${#VECCHIA_RADICE} vs ${#NUOVA_RADICE})." >&2
    echo "   install_name_tool would have to reallocate the load commands: stopping here." >&2
    exit 1
fi

# ⚠️ Da qui in giu' ogni comando porta il suo `|| true`, e non e' pigrizia.
# Lo script gira con `set -euo pipefail`: `otool` che esce diverso da zero su
# un file qualsiasi, o un `grep -q` che semplicemente non trova niente — cioe'
# il caso normale su mille file puliti — basta a terminare il build in
# silenzio. E' successo al primo lancio: si e' fermato subito dopo aver
# stampato i due percorsi, senza un errore, e `tail` in fondo alla pipe
# restituiva 0 facendolo sembrare riuscito.
RISCRITTI=0
while IFS= read -r macho; do
    # Le librerie portano anche il proprio nome, e va cambiato per primo:
    # lasciarlo indietro fa credere a dyld di avere due copie della stessa
    # libreria a percorsi diversi.
    PROPRIO="$(otool -D "$macho" 2>/dev/null | sed -n 2p || true)"
    case "$PROPRIO" in
        "$VECCHIA_RADICE"/*)
            install_name_tool -id "$NUOVA_RADICE/${PROPRIO#$VECCHIA_RADICE/}" "$macho" 2>/dev/null
            ;;
    esac

    otool -L "$macho" 2>/dev/null | grep -oE "$VECCHIA_RADICE/[^ ]+" | sort -u | \
    while IFS= read -r vecchio; do
        install_name_tool -change "$vecchio" "$NUOVA_RADICE/${vecchio#$VECCHIA_RADICE/}" "$macho" 2>/dev/null || true
    done || true

    # ⚠️ E gli rpath, che sono un'altra cosa e che -change non tocca.
    # httpd, mysqld, mysql e proftpd hanno un LC_RPATH verso la lib del vecchio
    # nome: e' il percorso in cui dyld cerca quando l'install name e' relativo.
    # Riscrivere solo le dipendenze e lasciare l'rpath sarebbe la peggiore
    # delle riuscite parziali — tutto sembra a posto a un otool -L, e il
    # pacchetto continua a dipendere da una cartella che vogliamo togliere.
    otool -l "$macho" 2>/dev/null | grep -A2 LC_RPATH | grep "^ *path " | \
    sed -E 's/^ *path (.*) \(offset.*/\1/' | while IFS= read -r rpath; do
        case "$rpath" in
            "$VECCHIA_RADICE"/*)
                install_name_tool -rpath "$rpath" "$NUOVA_RADICE/${rpath#$VECCHIA_RADICE/}" "$macho" 2>/dev/null || true
                ;;
        esac
    done || true
    RISCRITTI=$((RISCRITTI + 1))
# Stesso criterio della firma qui sotto: cosa il file e', non dove sta. E si
# guardano anche i file non eseguibili, perche' le .dylib e i .so non hanno il
# bit di esecuzione e sono la meta' del problema.
done < <(find "$PAYLOAD" -type f 2>/dev/null | while read -r f; do
    file -b "$f" 2>/dev/null | grep -q "Mach-O" || continue
    if otool -L "$f" 2>/dev/null | grep -q "$VECCHIA_RADICE" ||
       otool -l "$f" 2>/dev/null | grep -A2 LC_RPATH | grep -q "$VECCHIA_RADICE"; then
        echo "$f"
    fi
done || true)
echo "  $RISCRITTI binaries repointed"

# La prova che chiude: nemmeno un riferimento deve restare, ne' fra le
# dipendenze ne' fra gli rpath. Un conteggio, non un campione: e' l'unico
# controllo che distingue "l'ho fatto" da "funziona".
RESIDUI="$(find "$PAYLOAD" -type f 2>/dev/null | while read -r f; do
    file -b "$f" 2>/dev/null | grep -q "Mach-O" || continue
    if otool -L "$f" 2>/dev/null | grep -q "$VECCHIA_RADICE" ||
       otool -l "$f" 2>/dev/null | grep -A2 LC_RPATH | grep -q "$VECCHIA_RADICE"; then
        echo "$f"
    fi
done | wc -l | xargs || true)"
if [ "$RESIDUI" != "0" ]; then
    echo "!! $RESIDUI binaries still point at the old name: the package would need that folder" >&2
    exit 1
fi
echo "  no binary looks for the old name any more"

# ⚠️ Restano dentro i binari delle stringhe con il vecchio nome, e vanno
# distinte da quelle appena tolte perche' il rimedio e' diverso:
#
#   - i flag di compilazione, che proftpd -V stampa e nessuno apre: innocui;
#   - i percorsi di default — HTTPD_ROOT, il PidFile di proftpd, il datadir
#     di mysqld — che il binario usa davvero quando nessuno gliene passa uno.
#
# Quelli non si riscrivono: si scavalcano dicendo al demone quale file usare.
# httpd riceve -d e -f da apachectl, mysqld --defaults-file da mysql.server, e
# proftpd -c piu' PidFile qui sotto. E' il motivo per cui quelle tre patch non
# sono facoltative: senza, il pacchetto ha ancora bisogno della vecchia
# cartella anche con tutti gli install name a posto.
if [ -f "$PAYLOAD/etc/proftpd.conf" ] && ! grep -q "^PidFile" "$PAYLOAD/etc/proftpd.conf"; then
    cat >> "$PAYLOAD/etc/proftpd.conf" <<PROFTPD

# I due percorsi che proftpd si porta compilati dentro puntano al vecchio nome.
# Scritti qui, valgono piu' di quelli.
PidFile         "$NUOVA_RADICE/var/proftpd.pid"
ScoreboardFile  "$NUOVA_RADICE/var/proftpd.scoreboard"
PROFTPD
    echo "  proftpd: pid and scoreboard written down explicitly"
fi

# ⚠️ E infine i file che portano il vecchio nome nel PROPRIO nome. Il branding
# riscrive quello che sta dentro i file e rinomina le cartelle, ma questi tre
# erano rimasti: la cartella si chiama gia' vxost-control-panel e i file dentro
# no. Sono il pannello di controllo GTK del 2006, Python 2, scritto per Linux:
# su un prodotto solo per macOS che ha la sua app nativa non serve a niente, e
# l'unica cosa che fa e' mettere il vecchio nome dentro il pacchetto.
#
# ⛔ Si toglie un elenco deciso, non "tutto quello che si chiama cosi'": un
# find -delete su un nome fa fuori anche cio' che serve, e qui dentro c'e'
# anche la licenza GPL di terzi, che non si cancella mai.
rm -rf "$PAYLOAD/share/vxost-control-panel" 2>/dev/null || true
rm -f  "$PAYLOAD/etc/extra/httpd-xampp.conf~" 2>/dev/null || true

RESTI="$(find "$PAYLOAD" -iname "*xampp*" 2>/dev/null | wc -l | xargs)"
if [ "$RESTI" != "0" ]; then
    echo "!! $RESTI files still carry the old name in their own filename:" >&2
    find "$PAYLOAD" -iname "*xampp*" 2>/dev/null | sed "s|$PAYLOAD|  …|" >&2
    exit 1
fi
echo "  no file carries the old name any more"

# ------------------------------------------------------------- pear.conf ---
#
# Rilievo C della revisione del 10/09. etc/pear.conf e' PHP serializzato, e
# ogni stringa porta la propria lunghezza: s:45:"/Applications/XAMPP/...".
# La rinomina XAMPP -> VXOST ha accorciato i percorsi di tre byte senza
# toccare i numeri, e unserialize() si ferma al primo che non torna:
# "Error at offset 684". pear e pecl non partono piu', e la guida su Xdebug
# insegna un comando che fallisce alla prima riga.
#
# Le lunghezze si ricalcolano dal contenuto, e poi si verifica che il file si
# legga davvero: una riparazione che non si prova e' una riparazione creduta.
step "Repairing the serialized lengths in pear.conf"
if [ -f "$PAYLOAD/etc/pear.conf" ]; then
    python3 - "$PAYLOAD/etc/pear.conf" <<'PYEOF'
import re, sys
path = sys.argv[1]
lines = open(path, encoding="utf-8").read().split("\n")
fixed = 0
def fix(m):
    global fixed
    declared, value = int(m.group(1)), m.group(2)
    real = len(value.encode("utf-8"))
    if real != declared:
        fixed += 1
    return f's:{real}:"{value}";'
# The serialized array is the second line; the first is the "#PEAR_Config" tag.
if len(lines) > 1:
    lines[1] = re.sub(r's:(\d+):"((?:[^"\\]|\\.)*?)";', fix, lines[1])
    open(path, "w", encoding="utf-8").write("\n".join(lines))
print(f"  pear.conf: {fixed} length(s) corrected")
PYEOF
    # La prova: il php del pacchetto deve leggere il file e trovarci un array.
    if [ -x "$PAYLOAD/bin/php" ]; then
        if ! "$PAYLOAD/bin/php" -n -r '$l = file($argv[1]); exit(is_array(@unserialize($l[1])) ? 0 : 1);' \
                "$PAYLOAD/etc/pear.conf" 2>/dev/null; then
            echo "!! pear.conf does not unserialize: pear and pecl would not start" >&2
            exit 1
        fi
        echo "  pear.conf: unserialize() reads it"
    else
        echo "  pear.conf: NOT VERIFIED, no runnable php in the payload"
    fi
fi

step "Signing the binaries"
# ⚠️ Si cerca in tutto il payload e non in un elenco di cartelle: un plugin
# di MariaDB stava sotto share/, fuori da ogni cartella che uno si aspetta, e
# un elenco scritto a mano lo saltava. Il criterio giusto e' cosa il file e',
# non dove sta.
#
# ⛔ E nemmeno il bit di esecuzione. Le librerie — .dylib, i moduli di Apache,
# i plugin di MariaDB — spesso non ce l'hanno, quindi `-perm +111` le
# saltava: restavano senza firma, e Gatekeeper le blocca esattamente come
# blocca un eseguibile. Un Apache firmato che carica un modulo non firmato
# non parte, e l'errore parla del modulo, non della firma.
mach_o_files() {
    find "$PAYLOAD" -type f 2>/dev/null | while read -r f; do
        file "$f" 2>/dev/null | grep -q "Mach-O" && echo "$f"
    done
}

FIRMATI=0
FALLITI=0
NONFIRMATI=""
while IFS= read -r eseguibile; do
    if codesign --force --sign - --timestamp=none "$eseguibile" 2>/dev/null; then
        FIRMATI=$((FIRMATI + 1))
    else
        FALLITI=$((FALLITI + 1))
        NONFIRMATI="$NONFIRMATI  ${eseguibile#$PAYLOAD/}
"
    fi
done < <(mach_o_files)
echo "  $FIRMATI binaries signed ad-hoc"

# ⛔ Una firma fallita fermava il conteggio e non la build.
#
# Il file usciva nel pacchetto senza firma, e sul Mac di chi scarica
# l'attributo di quarantena piu' l'assenza di firma vuol dire SIGKILL: il
# componente muore all'avvio e nel Terminale si legge soltanto "Killed: 9".
if [ "$FALLITI" -ne 0 ]; then
    echo "!! $FALLITI binaries could not be signed:" >&2
    printf '%s' "$NONFIRMATI" >&2
    echo "   Unsigned binaries are killed by Gatekeeper on any Mac that" >&2
    echo "   downloads the package." >&2
    exit 1
fi

# La prova che conta: un binario preso a caso deve risultare firmato.
#
# ⚠️ Si cerca "adhoc" fra i flag del CodeDirectory, non la riga
# "Signature=adhoc": quella codesign la stampa solo per i bundle, e su un
# eseguibile sciolto non compare mai. Cercandola, la verifica diceva sempre di
# no su binari che erano firmati benissimo.
# ⚠️ Niente `grep -q` in fondo a una pipe, con set -o pipefail attivo.
#
# grep -q chiude la pipe appena trova la riga; codesign, che sta ancora
# scrivendo, riceve SIGPIPE e muore con 141; pipefail prende quel 141 come
# esito dell'intera pipe. Risultato: il controllo falliva **proprio quando** la
# firma c'era, e diceva "still unsigned" su binari firmati benissimo.
#
# L'output si raccoglie prima e si guarda dopo: nessuna pipe da chiudere.
# ⚠️ Si verificano tutti, non uno.
#
# Prima la prova era su bin/mysql soltanto: bastava a dire che codesign
# funzionava su questa macchina, non che il pacchetto fosse a posto. Un
# qualsiasi altro binario rimasto indietro sarebbe uscito lo stesso.
NONVERIFICATI=0
while IFS= read -r binario; do
    FIRMA="$(codesign -dv "$binario" 2>&1 || true)"
    case "$FIRMA" in
        *adhoc*) ;;
        *) NONVERIFICATI=$((NONVERIFICATI + 1))
           echo "  ⚠ unsigned: ${binario#$PAYLOAD/}" >&2 ;;
    esac
done < <(mach_o_files)

if [ "$NONVERIFICATI" -ne 0 ]; then
    echo "!! $NONVERIFICATI binaries are still unsigned" >&2
    exit 1
fi
echo "  all $FIRMATI verified"

step "Adding the VXOST app"
APP_BUNDLE="$HERE/build/VXOST.app"
[ -d "$APP_BUNDLE" ] || { echo "  build/VXOST.app missing, run make first" >&2; exit 1; }

# ⚠️ Esserci non basta. Il bundle esaminato il 07/09 era universale ma con
# minos 16.0 su entrambe le slice, per un prodotto che promette macOS 13: su
# Ventura e Sonoma non si sarebbe aperto. E un bundle di ieri porta la
# versione di ieri. Prima di copiarlo si controllano versione, architetture,
# deployment target di ogni slice, firma e data rispetto ai sorgenti.
_bin="$APP_BUNDLE/Contents/MacOS/VXOST"
_plist="$APP_BUNDLE/Contents/Info.plist"
_app_version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$_plist" 2>/dev/null || echo none)"
_min="$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$HERE/Resources/Info.plist")"
if [ "$_app_version" != "$VERSION" ]; then
    echo "!! build/VXOST.app is version $_app_version, the release is $VERSION: run make" >&2
    exit 1
fi
_archs="$(lipo -archs "$_bin" 2>/dev/null || echo none)"
for _arch in arm64 x86_64; do
    case " $_archs " in *" $_arch "*) ;; *)
        echo "!! the app has no $_arch slice ($_archs): every Mac of the other kind is left out" >&2
        exit 1 ;;
    esac
    _minos="$(otool -arch "$_arch" -l "$_bin" 2>/dev/null | awk '/LC_BUILD_VERSION/{f=1} f && /minos/{print $2; exit}')"
    if [ "${_minos%.0}" != "${_min%.0}" ]; then
        echo "!! the $_arch slice has minos ${_minos:-none}, Info.plist promises $_min: run make" >&2
        exit 1
    fi
done
if ! codesign --verify --deep --strict "$APP_BUNDLE" 2>/dev/null; then
    echo "!! the app signature does not verify: run make" >&2
    exit 1
fi
_newer="$(find "$HERE/src" "$HERE/Resources" -type f -newer "$_bin" -print -quit 2>/dev/null || true)"
if [ -n "$_newer" ]; then
    echo "!! ${_newer#$HERE/} is newer than the app binary: this bundle is an older build, run make" >&2
    exit 1
fi
cp -R "$APP_BUNDLE" "$STAGE/"
echo "  VXOST.app $_app_version, $_archs, minos $_min, signed, newer than every source"

# ----------------------------------------------------------------- verify ---

step "Checking for anything personal"
# One walk for every word, instead of one walk per word: the old form scanned
# 900 MB seventy times over and took minutes. See tools/verify-package.py for
# why an occurrence right after "github.com/" does not count as a leak.
#
# ⚠️ Si guarda quello che PARTE, non la cartella di lavoro. Il disco contiene
# vxostfiles e VXOST.app: il resto dello staging sono appunti di questo
# script, e accusarli vuol dire fermare la build per un file che nessuno
# ricevera'. E' successo il 11/09/2026, alla prima esecuzione vera, con il
# log di mysqld: due minuti di build buttati e un difetto che non c'era.
#
# Guardare meno non e' guardare peggio: quello che non parte non e' un
# problema di chi installa, e quello che parte viene guardato tutto.
for _spedito in vxostfiles VXOST.app; do
    if [ ! -e "$STAGE/$_spedito" ]; then
        echo "!! $_spedito is not in the staging: nothing to check" >&2
        exit 1
    fi
    if ! printf '%s\n' "${FORBIDDEN[@]}" | python3 "$HERE/tools/verify-package.py" "$STAGE/$_spedito"; then
        echo
        echo "Refusing to package: personal data found in $_spedito." >&2
        exit 1
    fi
done

# Una chiave privata non contiene il nome di nessuno, quindi il controllo qui
# sopra la lascerebbe passare: cerca parole, e una chiave e' base64. Si guarda
# per quello che e', non per quello che dice.
#
# ⚠️ E si guarda il contenuto, non l'estensione. phpmyadmin porta con se'
# vendor/composer/ca-bundle/res/cacert.pem, che e' l'elenco delle autorita' di
# cui fidarsi: stessa estensione di una chiave, significato opposto. Quello che
# distingue una chiave e' la riga che si dichiara tale.
#
# ⚠️ E non basta cercare il marcatore ovunque: i binari di PHP lo contengono
# perche' sanno leggere le chiavi, e le pagine di manuale di OpenSSL perche'
# le spiegano. Parlare di una chiave non e' esserlo. Una chiave vera e' un
# file piccolo che *comincia* con quel marcatore.
#
# ⚠️ Due criteri, perche' uno solo non basta.
#
#   1. il marcatore PEM all'inizio di una riga, nei primi 4 KB. Erano 200
#      byte, e non bastano: una chiave esportata da openssl puo' portarsi
#      davanti Bag Attributes o un blocco di intestazione, e il marcatore
#      finisce piu' in basso. L'ancora a inizio riga tiene fuori i manuali,
#      dove il marcatore compare indentato dentro un esempio.
#   2. l'estensione. Una chiave in formato DER e' binaria e non contiene
#      nessun marcatore: il primo criterio non la vedrebbe mai, per quanto si
#      allarghi la finestra. Il nome e' l'unica cosa che resta.
#
# Nessuno dei due dimostra l'assenza di una chiave: dimostrano l'assenza
# delle chiavi che sappiamo riconoscere. E' un controllo, non una garanzia.
step "Checking no private key got in"
# ⚠️ Per nome si rifiutano solo i formati che sono SEMPRE chiavi: .key, .p12,
# .pfx, .der. Un .pem puo' essere una chiave o un bundle pubblico di CA:
# phpmyadmin/vendor/composer/ca-bundle/res/cacert.pem e' il secondo, sta nella
# sorgente (216 KB, quindi fuori dal controllo sul contenuto dei file piccoli),
# e la vecchia regola lo rifiutava per l'estensione. Un .pem si giudica dal
# contenuto, tutto il file: "PRIVATE KEY" dentro e' una chiave, altrimenti
# sono certificati e possono viaggiare. Togliere il bundle o la verifica non
# era una scelta: composer e la parte HTTP di phpMyAdmin lo usano.
LEAKED="$( {
    find "$STAGE" -type f -size -100k -not -name "*.pem" 2>/dev/null | while IFS= read -r f; do
        head -c 4096 "$f" 2>/dev/null | grep -qE '^-----BEGIN [A-Z ]*PRIVATE KEY-----' && echo "$f"
    done
    find "$STAGE" -type f \( -name "*.key" -o -name "*.p12" -o -name "*.pfx" -o -name "*.der" \) 2>/dev/null
    find "$STAGE" -type f -name "*.pem" 2>/dev/null | while IFS= read -r f; do
        grep -qE '^-----BEGIN [A-Z ]*PRIVATE KEY-----' "$f" 2>/dev/null && echo "$f"
    done
} || true)"
if [ -n "$LEAKED" ]; then
    echo "$LEAKED" | sed 's|^|  |'
    echo
    echo "Refusing to package: a private key is inside." >&2
    exit 1
fi
echo "  none"

step "Checking the configuration still works"
# Vanno bene tutte e due le forme, e quella con l'indirizzo e' preferibile:
#
#   Listen 80              ascolta su ogni interfaccia, cioe' i progetti sono
#                          visibili a chiunque sia sulla stessa rete
#   Listen 127.0.0.1:80    solo questa macchina
#
# Il pacchetto esce chiuso, deciso il 14/08: aprire alla rete e' una scelta di
# sicurezza e la fa l'utente nel wizard, non noi al posto suo. Il controllo qui
# serve a un'altra cosa — che una direttiva Listen sulla 80 ci sia, perche'
# senza Apache non parte affatto.
# Dall'11/09 la forma e' una sola, e si verifica quella: il reset qui sopra
# riscrive le due Listen su 127.0.0.1, e se una e' rimasta senza indirizzo il
# pacchetto uscirebbe aperto alla rete di chiunque lo installa.
if ! grep -qE '^[[:space:]]*Listen[[:space:]]+127\.0\.0\.1:80([[:space:]]|$)' "$PAYLOAD/etc/httpd.conf"; then
    echo "!! httpd.conf: no 'Listen 127.0.0.1:80'. Found: $(grep -E '^[[:space:]]*Listen' "$PAYLOAD/etc/httpd.conf" | xargs || echo none)" >&2
    exit 1
fi
if [ -f "$PAYLOAD/etc/extra/httpd-ssl.conf" ] \
   && ! grep -qE '^[[:space:]]*Listen[[:space:]]+127\.0\.0\.1:443([[:space:]]|$)' "$PAYLOAD/etc/extra/httpd-ssl.conf"; then
    echo "!! httpd-ssl.conf: no 'Listen 127.0.0.1:443'. Found: $(grep -E '^[[:space:]]*Listen' "$PAYLOAD/etc/extra/httpd-ssl.conf" | xargs || echo none)" >&2
    exit 1
fi
if grep -qE '^[[:space:]]*Listen[[:space:]]+[0-9]+([[:space:]]|$)' "$PAYLOAD/etc/httpd.conf" "$PAYLOAD/etc/extra/httpd-ssl.conf" 2>/dev/null; then
    echo "!! a Listen without an address survived: the package would ship open to the network" >&2
    exit 1
fi
echo "  listening on 127.0.0.1:80 and 127.0.0.1:443, closed by default"

# ⚠️ -d non basta, e il controllo validava un'altra installazione.
#
# httpd.conf porta ServerRoot "/Applications/VXOST/vxostfiles" in assoluto, e
# ServerRoot nel file vince su -d: Include relativi, moduli e i percorsi SSL
# venivano risolti nell'installazione reale della macchina che costruisce. Il
# test diceva "valid" della configurazione di casa, non del pacchetto.
# (httpd.apache.org/docs/2.4/programs/httpd.html)
#
# Si costruisce uno SPECCHIO temporaneo: un link a ogni cartella del payload
# tranne etc/, e una copia di etc/ con la radice riscritta sullo specchio. Il
# certificato di prova nasce dentro lo specchio, non nel payload: vxost-ssl-init
# deduce la radice dal proprio percorso, e chiamato dal link la trova li'. Poi
# httpd -t -D DUMP_INCLUDES elenca i file che ha letto, e devono stare TUTTI
# nello specchio: e' la dimostrazione, non una speranza.
if [ -e "$PAYLOAD/etc/ssl.key" ] || [ -e "$PAYLOAD/etc/ssl.crt" ]; then
    echo "!! the payload already carries a certificate: it would be the same for" >&2
    echo "   every install, with the private key in the clear. Stopping here." >&2
    exit 1
fi

MIRROR="$(mktemp -d /tmp/vxost-configtest.XXXXXX)"
_mirror_cleanup() { rm -rf "$MIRROR"; }
trap _mirror_cleanup EXIT INT TERM
for _entry in "$PAYLOAD"/* "$PAYLOAD"/.[!.]*; do
    [ -e "$_entry" ] || continue
    _name="$(basename "$_entry")"
    [ "$_name" = "etc" ] && continue
    ln -s "$_entry" "$MIRROR/$_name"
done
cp -R "$PAYLOAD/etc" "$MIRROR/etc"
find "$MIRROR/etc" -type f \( -name "*.conf" -o -name "*.ini" -o -name "*.cnf" \) -exec \
    sed -i '' "s|$NUOVA_RADICE|$MIRROR|g" {} +

# Il certificato di prova: nello specchio, mai nel payload.
if ! "$MIRROR/bin/vxost-ssl-init"; then
    echo "!! could not generate a test certificate: cannot validate the SSL config" >&2
    exit 1
fi
if [ ! -f "$MIRROR/etc/ssl.crt/server.crt" ]; then
    echo "!! vxost-ssl-init wrote the certificate somewhere else than the mirror" >&2
    exit 1
fi
if [ -e "$PAYLOAD/etc/ssl.key" ] || [ -e "$PAYLOAD/etc/ssl.crt" ]; then
    echo "!! the test certificate landed in the payload: it must not ship" >&2
    exit 1
fi

for _defines in "" "-DSSL -DPHP"; do
    # shellcheck disable=SC2086
    if "$MIRROR/bin/httpd" -t -d "$MIRROR" -f "$MIRROR/etc/httpd.conf" $_defines > /tmp/configtest.log 2>&1; then
        echo "  Apache configuration valid${_defines:+ with $_defines}"
    else
        echo "  Apache configuration is broken${_defines:+ with $_defines}:" >&2
        tail -5 /tmp/configtest.log >&2
        exit 1
    fi
done

# La prova di isolamento: ogni file letto sta nello specchio.
"$MIRROR/bin/httpd" -t -d "$MIRROR" -f "$MIRROR/etc/httpd.conf" -DSSL -DPHP -D DUMP_INCLUDES \
    > /tmp/configtest-includes.log 2>&1 || true
_read="$(awk '$1 ~ /^\([^)]*\)$/ && $2 ~ /^\// {print $2}' /tmp/configtest-includes.log)"
if [ -z "$_read" ]; then
    echo "!! httpd -D DUMP_INCLUDES listed nothing: cannot prove what was checked" >&2
    exit 1
fi
_outside="$(printf '%s\n' "$_read" | grep -v "^$MIRROR/" || true)"
if [ -n "$_outside" ]; then
    echo "!! the configuration test read files outside the package:" >&2
    printf '%s\n' "$_outside" | sed 's/^/     /' >&2
    exit 1
fi
echo "  $(printf '%s\n' "$_read" | wc -l | xargs) Include files read, all inside the package"

# ⚠️ DUMP_INCLUDES elenca gli Include, e nient'altro: moduli, DocumentRoot,
# certificati e log non compaiono. Una configurazione che carica un modulo da
# fuori lo supera senza una parola, provato. E i binari portano scritto dentro
# il percorso assoluto delle librerie, quindi avviarli dallo specchio carica
# comunque quelle dell'installazione vera: "ha funzionato in prova" non
# dimostra che il pacchetto sia completo. Le due cose che si possono davvero
# dimostrare le verifica questo:
#
#   - ogni direttiva che nomina un percorso punta dentro il pacchetto o a una
#     cartella di sistema;
#   - ogni dipendenza non di sistema di ogni Mach-O sta dentro il pacchetto,
#     quindi dopo l'installazione quel percorso esistera'.
if ! python3 "$HERE/tools/verify-isolation.py" "$MIRROR" "$PAYLOAD" "$NUOVA_RADICE" "$SOURCE"; then
    echo "!! the package leans on something outside itself" >&2
    exit 1
fi

_mirror_cleanup
trap - EXIT INT TERM
if [ -e "$PAYLOAD/etc/ssl.key" ] || [ -e "$PAYLOAD/etc/ssl.crt" ]; then
    echo "!! a certificate is in the payload: it must not ship" >&2
    exit 1
fi
echo "  no certificate in the payload"

# What follows are the three things that only break on a machine that has never
# had XAMPP on it. None of them can be caught by reading the config: they are
# folders and files that either exist or do not, and on the machine that builds
# the package they always do.
step "Checking a clean install would actually start"

# tmpdir, named by my.cnf and needed before MariaDB can even log why it failed.
tmpdir="$(grep -oE '^[[:space:]]*tmpdir[[:space:]]*=[[:space:]]*\S+' "$PAYLOAD/etc/my.cnf" 2>/dev/null | head -1 | sed -E 's/.*=[[:space:]]*//')"
if [ -n "$tmpdir" ]; then
    case "$tmpdir" in
        */temp/*) rel="temp/${tmpdir##*/temp/}" ;;
        *)        rel="" ;;
    esac
    if [ -n "$rel" ] && [ ! -d "$PAYLOAD/$rel" ]; then
        echo "  my.cnf wants $tmpdir but $rel is not in the package: MariaDB would not start" >&2
        exit 1
    fi
    echo "  MariaDB tmpdir: $rel present"
fi

# An index at the root of the web root, whatever its extension.
if ! ls "$PAYLOAD/$WEBROOT"/index.* >/dev/null 2>&1; then
    echo "  no index page in $WEBROOT: https://virtualhost/ would serve a listing" >&2
    exit 1
fi
echo "  web root index: $(basename "$(ls "$PAYLOAD/$WEBROOT"/index.* | head -1)")"

# And the error pages the config points at. They live beside the web root, not
# inside it: the Alias in httpd-multilang-errordoc.conf sends /error/ to
# vxostfiles/error/. Looking for them under www/ finds nothing and diagnoses a
# fault that is not there — which is exactly what happened on 04/09/2026.
if [ ! -f "$PAYLOAD/error/HTTP_NOT_FOUND.html.var" ]; then
    echo "  error/ pages missing: every ErrorDocument would point at nothing" >&2
    exit 1
fi
echo "  error pages: $(ls "$PAYLOAD/error"/*.html.var 2>/dev/null | wc -l | xargs) files"

# The folder startProFTPD() redirects into before doing anything else.
if grep -q 'var/proftpd/start.err' "$PAYLOAD/vxost" 2>/dev/null && [ ! -d "$PAYLOAD/var/proftpd" ]; then
    echo "  vxost writes var/proftpd/start.err but var/proftpd is not in the package: FTP could never start" >&2
    exit 1
fi
echo "  var/proftpd: present"

# The projects page is dynamic, and it is the one that ships.
if [ ! -f "$PAYLOAD/$WEBROOT/projects/index.php" ]; then
    echo "  no projects/index.php: the projects page would be a listing" >&2
    exit 1
fi
echo "  projects index: index.php"

# Il timbro: build-stack-dmg.sh confeziona solo uno staging che e' arrivato
# fin qui, e che nessuno ha toccato dopo. Sta nella radice dello staging,
# fuori da vxostfiles/ e dall'app, quindi non finisce nel disco.
#
# ⚠️ Non una data. Il primo timbro era l'ora, e il confezionamento si fidava
# di `find -newer`: basta cambiare un file e rimettergli la data di prima con
# `touch -t` perche' non trovi niente. Qui si scrive l'impronta del
# CONTENUTO, file per file, piu' la versione: un byte cambiato, un file
# aggiunto o tolto, un permesso diverso, un link che punta altrove o una
# release diversa e il disco non si costruisce. Costa un minuto di lettura,
# che su un rilascio e' niente.
step "Stamping the staging with what it contains"
if ! python3 "$HERE/tools/stage-manifest.py" "$STAGE" > "$STAGE/.verified.manifest"; then
    echo "!! could not read the staging in full: it cannot be stamped" >&2
    exit 1
fi
{
    echo "version=$VERSION"
    echo "manifest=$(shasum -a 256 "$STAGE/.verified.manifest" | cut -d" " -f1)"
    echo "files=$(wc -l < "$STAGE/.verified.manifest" | xargs)"
    echo "date=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$STAGE/.verified"
echo "  $(wc -l < "$STAGE/.verified.manifest" | xargs) entries, version $VERSION"

step "Done"
du -sh "$STAGE" | awk '{print "  staged:", $1}'
echo "  next: bash tools/build-stack-dmg.sh"
