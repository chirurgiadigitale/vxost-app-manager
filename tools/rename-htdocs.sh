#!/bin/bash
#
# Rinomina htdocs in www.
#
# ⚠️ E' la rinomina piu' delicata delle tre, e vale la pena dire perche' prima
# di lanciarla:
#
#   - htdocs compare nel DocumentRoot di OGNI virtual host. Rinominare la
#     cartella e basta manda giu' tutti i progetti locali.
#   - htdocs E' il repository git della dashboard. Rinominarla sposta un
#     repository, quindi dopo va rifatto il remote se qualcosa lo referenzia
#     per percorso.
#   - httpd.conf ha un DocumentRoot suo, e i default compilati dentro httpd
#     puntano a htdocs. Per quelli resta un symlink nascosto, come per il resto.
#
# L'app non ha bisogno di niente: XPPaths cerca prima www e poi htdocs.
#
# Copia i config, valida con httpd -t, e rimette tutto se non passa.
#
# Usage:
#   sudo bash rename-htdocs.sh check    guarda e basta
#   sudo bash rename-htdocs.sh apply    fallo
#
set -uo pipefail

ROOT="/Applications/VXOST/vxostfiles"
OLD="htdocs"
NEW="www"
MODE="${1:-check}"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$ROOT/backup/htdocs-$STAMP"

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
fail() { printf '  \033[31m✗ %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓ %s\033[0m\n' "$*"; }

say "Checking the ground"

[ "$(id -u)" -eq 0 ] || { fail "run this with sudo"; exit 1; }
ok "running as root"

if [ -d "$ROOT/$NEW" ] && [ ! -L "$ROOT/$NEW" ]; then
    ok "$NEW is already there, nothing to do"
    exit 0
fi
[ -d "$ROOT/$OLD" ] || { fail "$ROOT/$OLD is not there"; exit 1; }

running=""
for p in httpd mysqld proftpd; do
    pgrep -x "$p" >/dev/null 2>&1 && running="$running $p"
done
if [ -n "$running" ]; then
    fail "still running:$running"
    echo "      sudo bash $(cd "$(dirname "$0")" && pwd)/stop-services.sh"
    exit 1
fi
ok "all services are stopped"

# Ogni file di configurazione che nomina la cartella, sotto qualsiasi forma.
HITS="$(mktemp)"
grep -rl --include="*.conf" --include="*.ini" "/$OLD" "$ROOT/etc" 2>/dev/null > "$HITS" || true
hits=$(wc -l < "$HITS" | tr -d ' ')
echo "  $hits configuration files mention it:"
while IFS= read -r f; do
    [ -n "$f" ] || continue
    printf '      %-44s %s references\n' "${f#$ROOT/}" "$(grep -c "/$OLD" "$f")"
done < "$HITS" | head -8

docroots=$(grep -rh --include="*.conf" "DocumentRoot.*/$OLD" "$ROOT/etc" 2>/dev/null | wc -l | tr -d ' ')
echo "  $docroots DocumentRoot lines point inside it"

if [ -d "$ROOT/$OLD/.git" ]; then
    echo "  ⚠️  it is a git repository: $(cd "$ROOT/$OLD" && git rev-parse --abbrev-ref HEAD 2>/dev/null)"
    dirty=$(cd "$ROOT/$OLD" && git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    if [ "$dirty" -ne 0 ]; then
        fail "$dirty uncommitted changes. Commit them first, a rename is not the moment to lose them."
        rm -f "$HITS"
        exit 1
    fi
    ok "working tree is clean"
fi

if [ "$MODE" != "apply" ]; then
    rm -f "$HITS"
    say "Check only. Nothing was changed."
    echo "  Run with 'apply' to go ahead."
    exit 0
fi

# ----------------------------------------------------------------- apply ---

say "Backing the configuration up"
mkdir -p "$BACKUP"
while IFS= read -r f; do
    [ -n "$f" ] || continue
    rel="${f#$ROOT/}"
    mkdir -p "$BACKUP/$(dirname "$rel")"
    cp "$f" "$BACKUP/$rel"
done < "$HITS"
ok "$BACKUP"

rollback() {
    say "Rolling back"
    [ -L "$ROOT/$OLD" ] && rm -f "$ROOT/$OLD"
    [ -d "$ROOT/$NEW" ] && mv "$ROOT/$NEW" "$ROOT/$OLD"
    (cd "$BACKUP" && find . -type f -exec cp {} "$ROOT"/{} \;) 2>/dev/null
    fail "put back as it was"
}

say "Renaming the folder"
mv "$ROOT/$OLD" "$ROOT/$NEW" || { fail "rename failed"; exit 1; }
ok "$OLD -> $NEW"

say "Rewriting the paths"
while IFS= read -r f; do
    [ -n "$f" ] || continue
    perl -pi -e "s{/\Q$OLD\E}{/$NEW}g" "$f"
    printf '  %s\n' "${f#$ROOT/}"
done < "$HITS"
rm -f "$HITS"

say "Leaving the old name reachable, hidden"
# I default compilati dentro httpd puntano a htdocs e non si possono cambiare
# senza ricompilare.
ln -s "$NEW" "$ROOT/$OLD"
chflags -h hidden "$ROOT/$OLD" 2>/dev/null
ok "$OLD -> $NEW, hidden"

# Anche il collegamento comodo accanto a vxostfiles.
if [ -L "$ROOT/../$OLD" ]; then
    rm -f "$ROOT/../$OLD"
    ln -s "vxostfiles/$NEW" "$ROOT/../$NEW"
    ok "../$OLD -> ../$NEW"
fi

say "Checking Apache still parses"
configtest="$("$ROOT/bin/httpd" -t -d "$ROOT" -f "$ROOT/etc/httpd.conf" 2>&1 || true)"
if printf '%s' "$configtest" | grep -qi "Syntax OK"; then
    ok "Syntax OK"
else
    fail "the configuration no longer parses:"
    printf '%s' "$configtest" | head -6 | sed 's/^/      /'
    rollback
    exit 1
fi

say "Done"
echo "  Start again and open a couple of projects before trusting it:"
echo "      sudo $ROOT/vxost start"
echo
echo "  The web root is now $ROOT/$NEW"
echo "  The dashboard repository moved with it: cd $ROOT/$NEW"
