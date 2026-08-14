#!/bin/bash
#
# Avvia e ferma un pool php-fpm per una versione di PHP di Homebrew.
#
# Un pool per versione, ognuno sul suo socket, e i progetti scelgono quale
# usare dal proprio virtual host. La versione compilata nello stack resta
# quella predefinita e continua a passare da mod_php: chi non chiede niente
# non si accorge di nulla.
#
# ⚠️ I pool girano come l'utente, non come root. Un php-fpm che gira da root
# esegue il codice dei progetti con tutti i permessi della macchina, ed e' un
# prezzo che non vale la comodita'. Apache ci parla attraverso un socket, e il
# socket ha i permessi giusti perche' possa leggerlo.
#
# Usage:
#   bash php-pool.sh list             cosa gira adesso
#   bash php-pool.sh start 8.2        avvia il pool per quella versione
#   bash php-pool.sh stop 8.2         fermalo
#   bash php-pool.sh stop all         ferma tutti
#
set -uo pipefail

ACTION="${1:-list}"
VERSION="${2:-}"
# ⚠️ NON la cartella temporanea dell'utente.
#
# Su macOS $TMPDIR e' /var/folders/<hash>/T ed e' drwx------ dell'utente:
# Apache, che gira come daemon, non riesce nemmeno ad attraversarla per
# arrivare al socket. E' lo stesso muro contro cui aveva sbattuto mkcert.
# /tmp e' attraversabile da tutti, ed e' li' che il socket deve stare.
RUNTIME="/tmp"

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
fail() { printf '  \033[31m✗ %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓ %s\033[0m\n' "$*"; }

# Il prefisso Homebrew per una versione: php@8.2, oppure php se e' la corrente.
prefix_for() {
    local want="$1"
    for base in /opt/homebrew/opt /usr/local/opt; do
        for d in "$base/php@$want" "$base/php"; do
            [ -x "$d/bin/php" ] || continue
            local have
            have="$("$d/bin/php" -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null)"
            [ "$have" = "$want" ] && { printf '%s' "$d"; return 0; }
        done
    done
    return 1
}

socket_for() { printf '%s/vxost-php%s.sock' "$RUNTIME" "${1//./}"; }
conf_for()   { printf '%s/vxost-php%s.conf' "$RUNTIME" "${1//./}"; }
pid_for()    { printf '%s/vxost-php%s.pid'  "$RUNTIME" "${1//./}"; }

case "$ACTION" in

list)
    say "Pools"
    found=0
    for s in "$RUNTIME"/vxost-php*.sock; do
        [ -S "$s" ] || continue
        v="$(basename "$s" .sock)"; v="${v#vxost-php}"
        pid="$(cat "$RUNTIME/vxost-php$v.pid" 2>/dev/null || true)"
        alive="no"
        [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && alive="yes"
        printf '  php %-6s socket %-34s running: %s\n' "$v" "$s" "$alive"
        found=$((found + 1))
    done
    [ "$found" -eq 0 ] && echo "  none running. Every project is using the stack version."
    ;;

start)
    [ -n "$VERSION" ] || { fail "which version? bash php-pool.sh start 8.2"; exit 1; }

    say "Looking for PHP $VERSION"
    PREFIX="$(prefix_for "$VERSION")" || {
        fail "PHP $VERSION is not installed via Homebrew"
        echo "      brew install php@$VERSION"
        exit 1
    }
    ok "$PREFIX"

    FPM="$PREFIX/sbin/php-fpm"
    [ -x "$FPM" ] || { fail "$FPM is not there"; exit 1; }

    SOCK="$(socket_for "$VERSION")"
    CONF="$(conf_for "$VERSION")"
    PIDF="$(pid_for "$VERSION")"

    if [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; then
        ok "already running on $SOCK"
        exit 0
    fi

    say "Writing the pool configuration"
    # ⚠️ Niente listen.owner e listen.group.
    #
    # Cambiare il gruppo di un socket e' un privilegio di root, e questo pool
    # gira come utente: php-fpm rifiuta di partire con "failed to chown() the
    # socket, Operation not permitted". Non e' un permesso mancante da
    # aggiungere, e' la conseguenza di una scelta.
    #
    # Apache gira come daemon e non condivide alcun gruppo con l'utente,
    # quindi il socket e' 0666. Su una macchina di sviluppo con un utente solo
    # e' accettabile; su una macchina condivisa vorrebbe dire che chiunque puo'
    # far eseguire PHP con i permessi di chi ha avviato il pool, ed e' il
    # motivo per cui il socket sta in /tmp e non nel web root.
    cat > "$CONF" <<CONF
; Generato da VXOST. Si puo' cancellare, viene riscritto al prossimo avvio.
[global]
pid = $PIDF
error_log = $RUNTIME/vxost-php${VERSION//./}.log
daemonize = yes

[vxost]
listen = $SOCK
listen.mode = 0666

pm = dynamic
pm.max_children = 10
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 3
CONF
    ok "$CONF"

    say "Starting"
    # L'output non si butta via: se fallisce, il motivo serve.
    output="$("$FPM" --fpm-config "$CONF" 2>&1)" || {
        fail "php-fpm refused to start:"
        printf '%s\n' "$output" | head -6 | sed 's/^/      /'
        exit 1
    }

    # Il socket compare un istante dopo il fork.
    i=0
    while [ $i -lt 10 ] && [ ! -S "$SOCK" ]; do sleep 1; i=$((i + 1)); done

    if [ -S "$SOCK" ]; then
        ok "php $VERSION on $SOCK"
        echo
        echo "  To use it in a project, inside its <VirtualHost> block:"
        echo
        echo '      <FilesMatch "\.php$">'
        echo "          SetHandler \"proxy:unix:$SOCK|fcgi://localhost\""
        echo '      </FilesMatch>'
    else
        fail "started but no socket appeared at $SOCK"
        [ -f "$RUNTIME/vxost-php${VERSION//./}.log" ] && \
            tail -5 "$RUNTIME/vxost-php${VERSION//./}.log" | sed 's/^/      /'
        exit 1
    fi
    ;;

stop)
    [ -n "$VERSION" ] || { fail "which version? or 'all'"; exit 1; }
    say "Stopping"
    stopped=0
    for PIDF in "$RUNTIME"/vxost-php*.pid; do
        [ -f "$PIDF" ] || continue
        v="$(basename "$PIDF" .pid)"; v="${v#vxost-php}"
        if [ "$VERSION" != "all" ] && [ "$v" != "${VERSION//./}" ]; then continue; fi
        pid="$(cat "$PIDF" 2>/dev/null || true)"
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            kill -QUIT "$pid" 2>/dev/null
            ok "php $v stopped"
            stopped=$((stopped + 1))
        fi
        rm -f "$PIDF" "$RUNTIME/vxost-php$v.sock" "$RUNTIME/vxost-php$v.conf"
    done
    [ "$stopped" -eq 0 ] && echo "  nothing was running"
    ;;

*)
    echo "usage: php-pool.sh [list|start <version>|stop <version|all>]"
    exit 2
    ;;
esac
