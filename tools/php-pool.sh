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
    # ⛔ Ma 0666 in /tmp vuol dire che qualunque altro utente di questo Mac
    # puo' aprire il socket e parlare FastCGI al pool, cioe' far eseguire PHP
    # con l'identita' di chi lo ha avviato: i suoi file, le sue chiavi, i suoi
    # database. Prima si prova a chiuderlo con una ACL, che php-fpm sa mettere
    # da se' senza essere root, e si riapre solo se non ce la fa.
    scrivi_conf() {
        cat > "$CONF" <<CONF
; Generato da VXOST. Si puo' cancellare, viene riscritto al prossimo avvio.
[global]
pid = $PIDF
error_log = $RUNTIME/vxost-php${VERSION//./}.log
daemonize = yes

[vxost]
listen = $SOCK
$1

pm = dynamic
pm.max_children = 10
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 3
CONF
    }

    # daemon e' l'utente di Apache nello stack, come da httpd.conf.
    scrivi_conf "listen.mode = 0600
listen.acl_users = daemon"
    ok "$CONF"

    say "Starting"
    # L'output non si butta via: se fallisce, il motivo serve.
    if ! output="$("$FPM" --fpm-config "$CONF" 2>&1)"; then
        # ⚠️ Si ripiega sul socket aperto SOLO se e' la ACL a non essere
        # supportata. php-fpm compilato senza --with-fpm-acl rifiuta la
        # direttiva con "unknown entry 'listen.acl_users'" (verificato con
        # quello di Homebrew, 11/09/2026), ed e' l'unico errore per cui
        # aprire il socket e' un rimedio. Qualunque altro (porta in uso, log
        # non scrivibile, php.ini rotto) si ripresenterebbe identico con 0666:
        # riprovare con i permessi allargati toglierebbe una protezione senza
        # risolvere niente.
        if ! printf '%s\n' "$output" | grep -q "unknown entry 'listen\.acl_"; then
            fail "php-fpm refused to start:"
            printf '%s\n' "$output" | head -6 | sed 's/^/      /'
            exit 1
        fi
        # Fra un pool esposto e nessun pool il primo almeno funziona, ma la
        # rinuncia si dice, non si nasconde.
        fail "this php-fpm does not support ACLs on the socket:"
        printf '%s\n' "$output" | head -3 | sed 's/^/      /'
        fail "falling back to a socket every user of this Mac can open"
        scrivi_conf "listen.mode = 0666"
        output="$("$FPM" --fpm-config "$CONF" 2>&1)" || {
            fail "php-fpm refused to start:"
            printf '%s\n' "$output" | head -6 | sed 's/^/      /'
            exit 1
        }
    fi

    # Il socket compare un istante dopo il fork.
    i=0
    while [ $i -lt 10 ] && [ ! -S "$SOCK" ]; do sleep 1; i=$((i + 1)); done

    # Il socket sul disco non basta: dietro ci deve essere il master vivo,
    # altrimenti Apache trova il file e nessuno che risponda (503).
    if [ -S "$SOCK" ] && [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF" 2>/dev/null)" 2>/dev/null; then
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
    # ⚠️ Tre contatori distinti (rilievo O): fermati, falliti, e "non c'era
    # niente". Prima l'ultima riga era `[ $stopped -eq 0 ] && echo ...`, che
    # dopo uno stop riuscito usciva 1 (il test falliva ed era l'ultimo
    # comando) e dopo un timeout diceva che niente girava e usciva 0.
    stopped=0
    failed=0
    for PIDF in "$RUNTIME"/vxost-php*.pid; do
        [ -f "$PIDF" ] || continue
        v="$(basename "$PIDF" .pid)"; v="${v#vxost-php}"
        if [ "$VERSION" != "all" ] && [ "$v" != "${VERSION//./}" ]; then continue; fi
        pid="$(cat "$PIDF" 2>/dev/null || true)"
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            # Il pid deve essere un php-fpm: un file pid vecchio puo' puntare
            # a qualunque processo abbia ereditato quel numero, e a quello
            # non si manda niente.
            case "$(ps -p "$pid" -o comm= 2>/dev/null)" in
                *php-fpm*) ;;
                *)
                    fail "pid $pid in $(basename "$PIDF") is not php-fpm: stale file, removed"
                    rm -f "$PIDF" "$RUNTIME/vxost-php$v.sock" "$RUNTIME/vxost-php$v.conf"
                    continue ;;
            esac
            kill -QUIT "$pid" 2>/dev/null
            # ⚠️ QUIT e' un arresto garbato: php-fpm finisce le richieste in
            # corso e poi esce. Annunciarlo fermo subito, e togliergli il
            # socket da sotto, vuol dire far fallire proprio quelle richieste
            # e lasciare in giro un processo che l'app non trova piu'.
            atteso=0
            while [ $atteso -lt 15 ] && kill -0 "$pid" 2>/dev/null; do
                sleep 1
                atteso=$((atteso + 1))
            done
            if kill -0 "$pid" 2>/dev/null; then
                fail "php $v did not stop within 15s (pid $pid), left as it is"
                failed=$((failed + 1))
                continue
            fi
            ok "php $v stopped"
            stopped=$((stopped + 1))
        fi
        rm -f "$PIDF" "$RUNTIME/vxost-php$v.sock" "$RUNTIME/vxost-php$v.conf"
    done
    if [ "$failed" -gt 0 ]; then
        fail "$failed pool(s) still running"
        exit 1
    fi
    [ "$stopped" -eq 0 ] && echo "  nothing was running"
    exit 0
    ;;

*)
    echo "usage: php-pool.sh [list|start <version>|stop <version|all>]"
    exit 2
    ;;
esac
