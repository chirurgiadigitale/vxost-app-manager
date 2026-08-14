#!/bin/bash
#
# Rinomina la cartella di stato lasciata indietro da finish-rename.sh.
#
# ⚠️ etc/xampp non e' documentazione, e' STATO. Dentro ci sono:
#
#   startssl      dice al comando di avvio di passare -DSSL ad Apache
#   rights_fixed  dice che il controllo dei permessi e' gia' stato fatto
#
# La rinomina ha riscritto il riferimento dentro lo script (lc="$ROOT/etc/vxost")
# senza spostare la cartella. Da li' in poi lo script cerca file che non trova,
# quindi Apache parte senza SSL, la porta 443 resta chiusa e https smette di
# rispondere. Senza un errore: cambia solo il comportamento.
#
# Usage: sudo bash fix-state-dir.sh
#
set -uo pipefail

ROOT="/Applications/VXOST/vxostfiles"
say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
fail() { printf '  \033[31m✗ %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓ %s\033[0m\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { fail "run this with sudo"; exit 1; }

say "Checking"
if [ -d "$ROOT/etc/vxost" ]; then
    ok "etc/vxost is already there"
    ls "$ROOT/etc/vxost" | sed 's/^/      /'
    exit 0
fi
if [ ! -d "$ROOT/etc/xampp" ]; then
    fail "neither etc/xampp nor etc/vxost is there"
    exit 1
fi
echo "  etc/xampp contains:"
ls "$ROOT/etc/xampp" | sed 's/^/      /'

say "Renaming"
mv "$ROOT/etc/xampp" "$ROOT/etc/vxost" || { fail "rename failed"; exit 1; }
ok "etc/xampp -> etc/vxost"

say "Checking the switches are where the script looks"
for f in startssl rights_fixed; do
    if [ -f "$ROOT/etc/vxost/$f" ]; then
        ok "$f"
    else
        echo "      $f is not there, which may be intentional"
    fi
done

say "Done"
echo "  Stop and start once, and Apache will pick up SSL again:"
echo "      sudo bash $(cd "$(dirname "$0")" && pwd)/stop-services.sh"
echo "      sudo $ROOT/vxost start"
