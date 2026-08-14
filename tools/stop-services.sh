#!/bin/bash
#
# Stops Apache, MySQL and ProFTPD, and does not lie about it.
#
# The control script that ships with the stack cannot be trusted here, and it
# is worth writing down why, because it has cost two afternoons.
#
#   - it decides whether a service is running by looking for a pid file. If the
#     file is missing it prints "not running." and returns success, while the
#     process is very much alive. Nothing downstream can tell the difference.
#   - it kills mysqld without touching mysqld_safe, which is a babysitter: it
#     notices its child die and starts a new one, so MySQL looks immortal.
#   - it prints "ok" when the kill returns zero, not when the process is gone.
#
# This one checks the process table, which is the only thing that knows the
# truth, and it does not return until the processes are actually gone.
#
# ⚠️ MySQL gets SIGTERM, never SIGKILL: SIGTERM is a clean shutdown that
# flushes InnoDB, SIGKILL leaves the next start to recover from a crash.
#
# Usage: sudo bash stop-services.sh
#
set -uo pipefail

ROOT=""
for _candidate in "/Applications/VXOST/vxostfiles" "/Applications/XAMPP/xamppfiles"; do
    [ -d "$_candidate" ] && { ROOT="$_candidate"; break; }
done
[ -n "$ROOT" ] || { echo "No installation found under /Applications." >&2; exit 1; }

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
fail() { printf '  \033[31m✗ %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓ %s\033[0m\n' "$*"; }

if [ "$(id -u)" -ne 0 ]; then
    fail "run this with sudo"
    exit 1
fi

# Aspetta che un processo sparisca davvero, invece di fidarsi di un messaggio.
wait_gone() {
    local pattern="$1" label="$2" seconds="${3:-20}" i=0
    while [ $i -lt "$seconds" ]; do
        pgrep -x "$pattern" >/dev/null 2>&1 || return 0
        sleep 1
        i=$((i + 1))
    done
    return 1
}

say "Apache"
if pgrep -x httpd >/dev/null 2>&1; then
    # ⚠️ Il segnale va al processo PADRE, letto dal suo file pid, non ad
    # apachectl.
    #
    # apachectl lancia `httpd -k stop` senza le opzioni con cui il server e'
    # partito, e su questo stack quel comando puo' uscire in errore prima di
    # segnalare alcunche'. Il 14/08 e' successo: Apache e' rimasto su e lo
    # script diceva di aver provato. Il padre ha un pid noto, quindi gli si
    # parla direttamente. E' quello che apachectl farebbe se funzionasse.
    master=""
    if [ -f "$ROOT/logs/httpd.pid" ]; then
        candidate="$(cat "$ROOT/logs/httpd.pid" 2>/dev/null | tr -d ' \n')"
        # Il file puo' essere vecchio e puntare a un pid riciclato da un altro
        # programma: si controlla che quel processo sia davvero httpd.
        case "$(ps -p "$candidate" -o comm= 2>/dev/null)" in
            *httpd) master="$candidate" ;;
        esac
    fi
    [ -n "$master" ] || master="$(pgrep -x httpd | head -1)"

    if [ -n "$master" ]; then
        echo "  parent process: $master"
        # L'esito del kill si guarda. Buttarlo via e' il modo per non sapere se
        # il segnale e' stato rifiutato o accettato e ignorato.
        if kill -TERM "$master"; then
            echo "  SIGTERM delivered"
        else
            fail "SIGTERM was refused"
        fi
    fi

    if wait_gone httpd "Apache" 15; then
        ok "stopped"
    else
        echo "  still there after 15s, this is what apachectl has to say:"
        # ⛔ L'output NON si butta via. La prima versione di questo script lo
        # mandava in /dev/null e il fallimento diceva solo "Apache is still
        # running", che e' la cosa gia' ovvia. Stesso errore fatto con mkcert
        # poche ore prima.
        "$ROOT/bin/apachectl" -k stop 2>&1 | sed 's/^/      /'
        pkill -TERM -x httpd 2>/dev/null
        if wait_gone httpd "Apache" 10; then
            ok "stopped"
        else
            # ⚠️ SIGKILL, e solo per Apache.
            #
            # Un server web non ha niente da scaricare su disco: al massimo si
            # perde una richiesta in corso, e qui non c'e' nessuno a farla.
            # MySQL e' un altro paio di maniche e infatti sopra non lo tocca
            # nessuno: li' SIGKILL lascerebbe il recupero da crash al riavvio.
            #
            # Serve perche' su questa macchina il padre resta vivo dopo tre
            # SIGTERM, pur essendo in stato S e senza segnali bloccati. Il
            # perche' e' ancora da capire, ma restare bloccati non e' una
            # opzione: il server va giu' comunque.
            echo "  three SIGTERMs ignored, using SIGKILL"
            echo "  it is safe here: a web server has nothing to flush to disk"
            pkill -KILL -x httpd 2>/dev/null
            if wait_gone httpd "Apache" 10; then
                ok "stopped"
                echo "      note: it took SIGKILL. Worth looking into, but not now."
            else
                fail "Apache survived SIGKILL, these are the processes left:"
                ps -eo pid,ppid,user,state,etime,command | grep httpd \
                    | grep -v grep | head -5 | sed 's/^/      /'
            fi
        fi
    fi
else
    ok "already stopped"
fi

say "MySQL"
if pgrep -x mysqld >/dev/null 2>&1 || pgrep -f "bin/mysqld_safe" >/dev/null 2>&1; then
    # ⚠️ Il guardiano per primo. Uccidendo mysqld mentre mysqld_safe e' vivo,
    # ne parte subito un altro e sembra che MySQL non si fermi mai.
    if pgrep -f "bin/mysqld_safe" >/dev/null 2>&1; then
        pkill -f "bin/mysqld_safe" 2>/dev/null
        # ⚠️ Non basta dormire un secondo. mysqld_safe resta in giro finche' il
        # figlio non ha finito di chiudere, e il controllo finale lo trovava
        # ancora vivo: lo script diceva di aver fallito quando aveva funzionato,
        # e bisognava rilanciarlo per sentirsi dire che era tutto a posto.
        i=0
        while [ $i -lt 30 ] && pgrep -f "bin/mysqld_safe" >/dev/null 2>&1; do
            sleep 1
            i=$((i + 1))
        done
        if pgrep -f "bin/mysqld_safe" >/dev/null 2>&1; then
            fail "mysqld_safe is still there after 30s"
        else
            ok "mysqld_safe stopped, nothing will restart it now"
        fi
    fi

    if pgrep -x mysqld >/dev/null 2>&1; then
        pkill -TERM -x mysqld 2>/dev/null
        echo "  waiting for InnoDB to flush, this can take a while on big databases"
        if wait_gone mysqld "MySQL" 60; then
            ok "stopped cleanly"
        else
            fail "still running after 60s"
            echo "      do NOT kill -9: the next start would have to recover from a crash"
            echo "      wait and check with: pgrep -lx mysqld"
            exit 1
        fi
    fi
else
    ok "already stopped"
fi

say "ProFTPD"
if pgrep -x proftpd >/dev/null 2>&1; then
    pkill -TERM -x proftpd 2>/dev/null
    wait_gone proftpd "ProFTPD" 10 && ok "stopped" || fail "ProFTPD is still running"
else
    ok "already stopped"
fi

say "Checking, from the process table and not from a message"
still=""
for p in httpd mysqld proftpd; do
    pgrep -x "$p" >/dev/null 2>&1 && still="$still $p"
done
pgrep -f "bin/mysqld_safe" >/dev/null 2>&1 && still="$still mysqld_safe"

if [ -n "$still" ]; then
    fail "still running:$still"
    exit 1
fi
ok "everything is down"
