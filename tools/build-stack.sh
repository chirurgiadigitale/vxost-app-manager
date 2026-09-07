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

    # Il ripiego con cp non conosce le esclusioni: se e' scattato, si tolgono
    # a mano. Senza questo, un rsync fallito farebbe uscire le chiavi.
    rm -rf "$PAYLOAD/$dir/ssl.key" "$PAYLOAD/$dir/ssl.crt"

    # A stray backup is enough to leak every virtual host ever configured.
    find "$PAYLOAD/$dir" \( -name "*.bak*" -o -name "*.orig" -o -name "*.save" \
         -o -name "*.old" -o -name "*~" \) -delete 2>/dev/null || true
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
mkdir -p "$PAYLOAD/logs" "$PAYLOAD/var" "$PAYLOAD/temp" "$PAYLOAD/temp/mysql" "$PAYLOAD/backup"
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

mkdir -p "$PAYLOAD/$WEBROOT/projects"
cat > "$PAYLOAD/$WEBROOT/projects/index.html" <<'HTML'
<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<title>Projects</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>body{font-family:-apple-system,sans-serif;background:#070B16;color:#E9EFFA;
display:grid;place-items:center;height:100vh;margin:0;text-align:center}
p{color:#8493AB;max-width:44ch;line-height:1.6}code{color:#FD47FD}</style>
</head><body><div>
<h1>No projects yet</h1>
<p>Put your sites in this folder and they will show up here, and in the
VXOST app, as soon as you give them a virtual host in
<code>etc/extra/httpd-vhosts.conf</code>.</p>
</div></body></html>
HTML

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
if [ -f "$PAYLOAD/bin/apachectl" ]; then
    perl -pi -e "s|^HTTPD='(.*)/bin/httpd'\s*$|HTTPD='\$1/bin/httpd -d \$1 -f \$1/etc/httpd.conf'\n|" \
        "$PAYLOAD/bin/apachectl"

    # lynx is not in the package and this URL is never fetched, but "localhost"
    # in a shipped file is a name we no longer use anywhere.
    sed -i '' 's|http://localhost:80/server-status|http://127.0.0.1:80/server-status|' \
        "$PAYLOAD/bin/apachectl"

    if grep -q "bin/httpd -d .* -f .*/etc/httpd.conf" "$PAYLOAD/bin/apachectl"; then
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
# Generate the SSL certificate the first time, on this Mac.
# Self-signed, CN=virtualhost, ten years. Nothing here leaves the machine.
VXOST_SSL_DIR='{prefix}/etc'
if [ ! -s "$VXOST_SSL_DIR/ssl.crt/server.crt" ] || [ ! -s "$VXOST_SSL_DIR/ssl.key/server.key" ]; then
  mkdir -p "$VXOST_SSL_DIR/ssl.crt" "$VXOST_SSL_DIR/ssl.key"
  '{prefix}/bin/openssl' req -new -x509 -nodes -newkey rsa:2048 \\
    -keyout "$VXOST_SSL_DIR/ssl.key/server.key" \\
    -out "$VXOST_SSL_DIR/ssl.crt/server.crt" \\
    -days 3650 -subj '/CN=virtualhost' >/dev/null 2>&1
  chmod 600 "$VXOST_SSL_DIR/ssl.key/server.key"
  chmod 644 "$VXOST_SSL_DIR/ssl.crt/server.crt"
fi
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

    if grep -q "CN=virtualhost" "$PAYLOAD/bin/apachectl"; then
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
    f'{indent}  *) chown -R mysql "$datadir" "$basedir/temp/mysql" 2>/dev/null || true ;;\n'
    f'{indent}esac\n'
)
open(path, "w", encoding="utf-8").write(text[:line_start] + block + text[line_start:])
PYEOF

    if grep -q 'temp/mysql' "$MYSQL_SERVER"; then
        echo "  mysql.server: tmpdir created and ownership repaired before start"
    else
        echo "!! mysql.server has no tmpdir step: MariaDB would not start" >&2
        exit 1
    fi

    if grep -q 'mysqld_safe --defaults-file=' "$MYSQL_SERVER"; then
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
    if grep -q 'logs/error\.log' "$PAYLOAD/share/vxost/diagnose"; then
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

# 1. La porta sbagliata. MariaDB ascolta sulla 3306, e my.cnf lo conferma.
text = text.replace("if testport 3308", "if testport 3306", 1)

# 2. L'avvio: si aspetta che la porta risponda davvero prima di dire ok.
#    Sessanta secondi perche' un recovery InnoDB dopo un arresto brusco ci
#    mette molto piu' dei pochi secondi che uno si aspetta.
avvio_vecchio = re.search(
    r"([ \t]*)\$VXOST_ROOT/bin/mysql\.server start > /dev/null &\s*\n"
    r".*?\n[ \t]*\$GETTEXT -s \"ok\.\"\s*\n[ \t]*return 0\s*\n",
    text, re.DOTALL)
if not avvio_vecchio:
    sys.stderr.write("!! vxost: startMySQL non ha la forma attesa, non lo tocco\n")
    sys.exit(1)

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
arresto_vecchio = re.search(
    r"([ \t]*)\$VXOST_ROOT/bin/mysql\.server stop > /dev/null 2>&1\s*\n"
    r"[ \t]*error=\$\?\s*\n"
    r".*?\n[ \t]*\$GETTEXT -s \"ok\.\"\s*\n[ \t]*return 0\s*\n",
    text, re.DOTALL)
if not arresto_vecchio:
    sys.stderr.write("!! vxost: stopMySQL non ha la forma attesa, non lo tocco\n")
    sys.exit(1)

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

if text == prima:
    sys.stderr.write("!! vxost: nessuna patch applicata\n")
    sys.exit(1)
open(path, "w", encoding="utf-8").write(text)
PYEOF

    # ⚠️ Nessun '$' nelle stringhe cercate: fra le virgolette la shell lo
    # espanderebbe, il grep cercherebbe una riga che non esiste e il controllo
    # direbbe di no su una patch entrata benissimo. Verificato: e' successo.
    for _atteso in "testport 3306" "atteso -lt 60" "MySQL is still listening" "proftpd -c"; do
        grep -q "$_atteso" "$PAYLOAD/vxost" || {
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
    sed -i '' -E 's/^skip-networking/#skip-networking/' "$PAYLOAD/etc/my.cnf"

    # It must listen on loopback only, though. Without bind-address MariaDB
    # answers on every interface, so anyone on the same wifi can reach the
    # database of a machine that was only meant to serve itself. This is the
    # protection the old security check was reaching for when it reached for
    # skip-networking instead and broke every project on the machine.
    if ! grep -qE '^[[:space:]]*bind-address' "$PAYLOAD/etc/my.cnf"; then
        perl -pi -e 'if (/^\[mysqld\]/ && !$done) {
            $_ .= "\n# Reachable from this computer only. Do not replace this with\n";
            $_ .= "# skip-networking, which would cut off every project that\n";
            $_ .= "# connects to 127.0.0.1:3306.\n";
            $_ .= "bind-address=127.0.0.1\n";
            $done = 1;
        }' "$PAYLOAD/etc/my.cnf"
        printf "  MySQL restricted to 127.0.0.1\n"
    fi
fi

# ---------------------------------------------------------------- database ---

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

"$PAYLOAD/sbin/mysqld" --defaults-file="$STAGE/init-my.cnf" \
    --init-file="$STAGE/db-init.sql" --skip-networking > /dev/null 2>&1 &
sleep 8

# Dropping the accounts is not enough: the hostname survives in the Aria
# transaction logs and inside the privilege tables until they are rebuilt.
printf "  rebuilding privilege tables\n"
"$PAYLOAD/bin/mysql" --socket="$PAYLOAD/var/mysql/mysql.sock" -u root -proot -e "
    INSERT INTO mysql.proxies_priv (Host, User, Proxied_host, Proxied_user, With_grant)
        VALUES ('localhost','root','','',1)
        ON DUPLICATE KEY UPDATE With_grant=1;
    OPTIMIZE TABLE mysql.proxies_priv, mysql.global_priv, mysql.db,
                   mysql.tables_priv, mysql.columns_priv, mysql.procs_priv;
    FLUSH PRIVILEGES;" > /dev/null 2>&1 || true

"$PAYLOAD/bin/mysqladmin" --socket="$PAYLOAD/var/mysql/mysql.sock" \
    -u root -proot shutdown > /dev/null 2>&1 || true
sleep 4
pkill -f "$PAYLOAD/sbin/mysqld" 2>/dev/null || true
sleep 2

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

step "Signing the binaries"
FIRMATI=0
while IFS= read -r eseguibile; do
    codesign --force --sign - --timestamp=none "$eseguibile" 2>/dev/null && \
        FIRMATI=$((FIRMATI + 1))
# ⚠️ Si cerca in tutto il payload e non in un elenco di cartelle: un plugin
# di MariaDB stava sotto share/, fuori da ogni cartella che uno si aspetta, e
# un elenco scritto a mano lo saltava. Il criterio giusto e' cosa il file e',
# non dove sta.
done < <(find "$PAYLOAD" -type f -perm +111 2>/dev/null | while read -r f; do
    file "$f" 2>/dev/null | grep -q "Mach-O" && echo "$f"
done)
echo "  $FIRMATI binaries signed ad-hoc"

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
FIRMA="$(codesign -dv "$PAYLOAD/bin/mysql" 2>&1 || true)"
case "$FIRMA" in
    *adhoc*) echo "  verified on bin/mysql" ;;
    *)       echo "  ⚠ bin/mysql is still unsigned" >&2; exit 1 ;;
esac

step "Adding the VXOST app"
cp -R "$HERE/build/VXOST.app" "$STAGE/" 2>/dev/null || {
    echo "  build/VXOST.app missing, run make first" >&2; exit 1; }

# ----------------------------------------------------------------- verify ---

step "Checking for anything personal"
# One walk for every word, instead of one walk per word: the old form scanned
# 900 MB seventy times over and took minutes. See tools/verify-package.py for
# why an occurrence right after "github.com/" does not count as a leak.
if ! printf '%s\n' "${FORBIDDEN[@]}" | python3 "$HERE/tools/verify-package.py" "$STAGE"; then
    echo
    echo "Refusing to package: personal data found." >&2
    exit 1
fi

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
step "Checking no private key got in"
LEAKED="$(find "$STAGE" -type f -size -100k 2>/dev/null | while IFS= read -r f; do
    head -c 200 "$f" 2>/dev/null | grep -q -- "-----BEGIN .*PRIVATE KEY-----" && echo "$f"
done || true)"
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
if ! grep -qE '^\s*Listen\s+([0-9.]+:)?80\b' "$PAYLOAD/etc/httpd.conf"; then
    echo "  no Listen on port 80: Apache would not start" >&2
    exit 1
fi
echo "  listening on port 80: $(grep -oE '^\s*Listen\s+([0-9.]+:)?80\b' "$PAYLOAD/etc/httpd.conf" | head -1 | xargs)"

if "$PAYLOAD/bin/httpd" -t -d "$PAYLOAD" -f "$PAYLOAD/etc/httpd.conf" > /tmp/configtest.log 2>&1; then
    echo "  Apache configuration valid"
else
    echo "  Apache configuration is broken:" >&2
    tail -5 /tmp/configtest.log >&2
    exit 1
fi

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

step "Done"
du -sh "$STAGE" | awk '{print "  staged:", $1}'
echo "  next: bash tools/build-stack-dmg.sh"
