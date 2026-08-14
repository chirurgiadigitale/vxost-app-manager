#!/bin/bash
#
# Le versioni di PHP disponibili su questa macchina, e come farle convivere.
#
# ⚠️ Il limite vero e' mod_php: Apache ne carica UNA sola, per tutta
# l'installazione. Non e' una scelta di VXOST, e' come funziona il modulo.
#
# La strada per averne piu' d'una e' php-fpm: ogni versione gira come processo
# suo su un socket, e il singolo virtual host sceglie quale usare con
#
#     <FilesMatch "\.php$">
#         SetHandler "proxy:unix:/percorso/al.sock|fcgi://localhost"
#     </FilesMatch>
#
# Quindi la versione si sceglie PER PROGETTO, non per installazione.
#
# Le versioni extra vengono da Homebrew, e questo va detto: chi scarica il DMG
# senza avere Homebrew ne vede una sola, quella compilata nello stack.
#
# Usage:
#   bash php-versions.sh              elenca cosa c'e'
#   bash php-versions.sh sockets      mostra i socket dei pool attivi
#
set -uo pipefail

ROOT=""
for _candidate in "/Applications/VXOST/vxostfiles" "/Applications/XAMPP/xamppfiles"; do
    [ -d "$_candidate" ] && { ROOT="$_candidate"; break; }
done

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓ %s\033[0m\n' "$*"; }
warn() { printf '  \033[33m! %s\033[0m\n' "$*"; }

say "The version compiled into the stack"
if [ -x "$ROOT/bin/php" ]; then
    v="$("$ROOT/bin/php" -r 'echo PHP_VERSION;' 2>/dev/null)"
    printf '  %-14s %s   served by mod_php, this is the default for every project\n' "vxost" "$v"
else
    warn "no php in the stack"
fi

say "Versions from Homebrew"
found=0
for prefix in /opt/homebrew/opt/php /usr/local/opt/php; do
    for d in "$prefix" "$prefix"@*; do
        [ -x "$d/bin/php" ] || continue
        v="$("$d/bin/php" -r 'echo PHP_VERSION;' 2>/dev/null)"
        [ -n "$v" ] || continue
        fpm="$d/sbin/php-fpm"
        if [ -x "$fpm" ]; then
            printf '  %-14s %-10s php-fpm ready\n' "$(basename "$d")" "$v"
            found=$((found + 1))
        else
            printf '  %-14s %-10s no php-fpm, cannot be used per project\n' "$(basename "$d")" "$v"
        fi
    done
done

if [ "$found" -eq 0 ]; then
    warn "none found"
    echo
    echo "  VXOST works perfectly well with the one version it ships. Several"
    echo "  versions at once is the thing that needs Homebrew, and installing it"
    echo "  is one line:"
    echo
    echo '      /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
    echo
    echo "  then, for the versions you want:"
    echo
    echo "      brew install php@8.1 php@8.3 php@8.4"
    echo
    echo "  Old versions live in a separate tap:"
    echo
    echo "      brew tap shivammathur/php"
    echo "      brew install shivammathur/php/php@7.4"
fi

say "What Apache needs, and whether it has it"
for m in proxy proxy_fcgi; do
    if grep -qE "^LoadModule ${m}_module" "$ROOT/etc/httpd.conf" 2>/dev/null; then
        ok "mod_$m is loaded"
    else
        warn "mod_$m is NOT loaded, several versions cannot work without it"
    fi
done

if [ "${1:-}" = "sockets" ]; then
    say "Pools running right now"
    running=0
    for s in /tmp/vxost-php*.sock; do
        [ -S "$s" ] || continue
        printf '  %s\n' "$s"
        running=$((running + 1))
    done
    [ "$running" -eq 0 ] && echo "  none. Start one with: bash php-pool.sh start 8.2"
fi

say "How a project picks a version"
echo "  In its <VirtualHost> block:"
echo
echo '      <FilesMatch "\.php$">'
echo '          SetHandler "proxy:unix:/tmp/vxost-php83.sock|fcgi://localhost"'
echo '      </FilesMatch>'
echo
echo "  Without that block the project uses the stack version through mod_php,"
echo "  which is what every existing project does today and keeps doing."
