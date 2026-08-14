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
    rsync -a --quiet \
          --exclude "tmp/" --exclude "*.sock" --exclude "*.pid" \
          --exclude "*.log" --exclude "*.err" \
          --exclude "*.bak" --exclude "*.bak-*" --exclude "*.bak.*" \
          --exclude "*.orig" --exclude "*.save" --exclude "*~" \
          --exclude "*.old" --exclude "*.backup" \
          "$SOURCE/$dir" "$PAYLOAD/" 2>/dev/null || \
    cp -R "$SOURCE/$dir" "$PAYLOAD/"

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
mkdir -p "$PAYLOAD/logs" "$PAYLOAD/var" "$PAYLOAD/temp" "$PAYLOAD/backup"
touch "$PAYLOAD/logs/.gitkeep"

# --------------------------------------------------------------- web root ---

step "Installing a clean web root"
mkdir -p "$PAYLOAD/$WEBROOT"
# Only the redesigned dashboard, never the projects sitting next to it.
copied=0
for item in dashboard index.html favicon.ico README.md; do
    if [ -e "$DASHBOARD_REPO/$item" ]; then
        cp -R "$DASHBOARD_REPO/$item" "$PAYLOAD/$WEBROOT/"
        copied=$((copied + 1))
    fi
done
if [ "$copied" -eq 0 ]; then
    echo "Nothing copied from $DASHBOARD_REPO: the package would ship an empty web root." >&2
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

step "Checking the configuration still works"
if ! grep -qE '^\s*Listen\s+80\b' "$PAYLOAD/etc/httpd.conf"; then
    echo "  Listen 80 is missing: Apache would not start" >&2
    exit 1
fi
echo "  Listen 80 present"

if "$PAYLOAD/bin/httpd" -t -d "$PAYLOAD" -f "$PAYLOAD/etc/httpd.conf" > /tmp/configtest.log 2>&1; then
    echo "  Apache configuration valid"
else
    echo "  Apache configuration is broken:" >&2
    tail -5 /tmp/configtest.log >&2
    exit 1
fi

step "Done"
du -sh "$STAGE" | awk '{print "  staged:", $1}'
echo "  next: bash tools/build-stack-dmg.sh"
