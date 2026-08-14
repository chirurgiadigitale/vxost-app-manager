#!/bin/bash
#
# Finishes the rename inside a live installation, after migrate-to-vxost.sh.
#
# The migration renames the folders. What stays behind is the control script,
# still called xampp, and the twenty scripts under share/ that it talks to. So
# every command a person types still reads XAMPP, which is exactly what should
# not happen any more.
#
# The set is self-contained: those scripts only call each other, so they are
# renamed together and nothing outside notices. The compiled binaries are a
# different matter and are not touched, they carry their install path inside
# and only a rebuild removes that; the hidden symlinks left by the migration
# keep them working.
#
# ⚠️ A hidden symlink is left at the old name as well. Ten years of habits,
# and every guide on the internet, say `xampp start`. Breaking that to prove a
# point costs more than it gains, and it stays hidden from the Finder.
#
# Usage:
#   sudo bash finish-rename.sh check    look only, change nothing
#   sudo bash finish-rename.sh apply    do it
#
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="/Applications/VXOST/vxostfiles"
MODE="${1:-check}"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$ROOT/backup/rename-$STAMP"

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
fail() { printf '  \033[31m✗ %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓ %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------- checks ---

say "Checking the ground"

if [ "$(id -u)" -ne 0 ]; then
    fail "run this with sudo"
    exit 1
fi
ok "running as root"

if [ ! -d "$ROOT" ]; then
    fail "$ROOT is not there. Run migrate-to-vxost.sh first."
    exit 1
fi
ok "the migration has been done"

running=""
for p in httpd mysqld proftpd; do
    pgrep -x "$p" >/dev/null 2>&1 && running="$running $p"
done
if [ -n "$running" ]; then
    fail "still running:$running"
    echo "      sudo bash $HERE/tools/stop-services.sh"
    exit 1
fi
ok "all services are stopped"

CONTROL=""
for _name in vxost xampp lampp; do
    [ -f "$ROOT/$_name" ] && ! [ -L "$ROOT/$_name" ] && { CONTROL="$_name"; break; }
done
if [ -z "$CONTROL" ]; then
    fail "no control script found in $ROOT"
    exit 1
fi
if [ "$CONTROL" = "vxost" ]; then
    ok "the control script is already called vxost, nothing to do"
    exit 0
fi
echo "  control script: $CONTROL"

leftovers=$(grep -rli "xampp" "$ROOT/share/xampp" "$ROOT/$CONTROL" 2>/dev/null | wc -l | tr -d ' ')
echo "  $leftovers files still carry the old name"

if [ "$MODE" != "apply" ]; then
    say "Check only. Nothing was changed."
    echo "  Run with 'apply' to go ahead."
    exit 0
fi

# ----------------------------------------------------------------- apply ---

say "Backing up what is about to change"
mkdir -p "$BACKUP"
cp "$ROOT/$CONTROL" "$BACKUP/$CONTROL"
# Un archivio invece di una copia: share/ contiene link e permessi che una
# copia ricorsiva ingenua perderebbe, e il ripristino deve essere fedele.
tar -cf "$BACKUP/share.tar" -C "$ROOT/share" xampp 2>/dev/null
[ -d "$ROOT/share/xampp-control-panel" ] && \
    tar -rf "$BACKUP/share.tar" -C "$ROOT/share" xampp-control-panel 2>/dev/null
ok "$BACKUP"

rollback() {
    say "Rolling back"
    rm -f "$ROOT/vxost"
    rm -rf "$ROOT/share/vxost" "$ROOT/share/vxost-control-panel"
    tar -xf "$BACKUP/share.tar" -C "$ROOT/share" 2>/dev/null
    cp "$BACKUP/$CONTROL" "$ROOT/$CONTROL"
    chmod 755 "$ROOT/$CONTROL"
    fail "put back as it was, from $BACKUP"
}

say "Renaming the control script"
mv "$ROOT/$CONTROL" "$ROOT/vxost" || { rollback; exit 1; }
chmod 755 "$ROOT/vxost"
ok "$CONTROL -> vxost"

say "Renaming the scripts it talks to"
if ! python3 "$HERE/tools/brand-stack.py" "$ROOT"; then
    rollback
    exit 1
fi

# La cartella del vecchio pannello di controllo: solo documentazione, ma porta
# il nome nel percorso.
if [ -d "$ROOT/share/xampp-control-panel" ]; then
    mv "$ROOT/share/xampp-control-panel" "$ROOT/share/vxost-control-panel"
    ok "share/xampp-control-panel -> share/vxost-control-panel"
fi

say "Leaving the old name reachable, hidden"
# Dieci anni di abitudini, e ogni guida in rete, dicono `xampp start`. Romperlo
# per principio costa piu' di quanto renda.
ln -s "vxost" "$ROOT/$CONTROL" 2>/dev/null
chflags -h hidden "$ROOT/$CONTROL" 2>/dev/null
ok "$CONTROL -> vxost, hidden"

say "Checking it actually works"
# ⚠️ Non basta che il file esista: deve rispondere. Un rinominatore che
# sbaglia una variabile lascia uno script che parte e non fa niente, e ce ne
# si accorgerebbe solo al primo avvio dei servizi.
if "$ROOT/vxost" 2>&1 | grep -qi "usage"; then
    ok "vxost answers"
else
    fail "the renamed script does not answer as expected"
    "$ROOT/vxost" 2>&1 | head -5 | sed 's/^/      /'
    rollback
    exit 1
fi

if "$ROOT/bin/httpd" -t -d "$ROOT" -f "$ROOT/etc/httpd.conf" 2>&1 | grep -qi "Syntax OK"; then
    ok "Apache configuration still parses"
else
    fail "the Apache configuration no longer parses"
    rollback
    exit 1
fi

say "Done"
echo "  From now on:"
echo "      sudo $ROOT/vxost start"
echo
echo "  The backup is in $BACKUP if anything looks wrong."
