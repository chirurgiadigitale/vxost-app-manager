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
    # apachectl parla al processo padre attraverso il suo file pid, che per
    # Apache esiste. E' la via pulita: chiude le connessioni in corso.
    "$ROOT/bin/apachectl" -k stop >/dev/null 2>&1
    if wait_gone httpd "Apache" 15; then
        ok "stopped"
    else
        echo "  still there after 15s, asking the remaining processes to quit"
        pkill -TERM -x httpd 2>/dev/null
        wait_gone httpd "Apache" 10 && ok "stopped" || fail "Apache is still running"
    fi
else
    ok "already stopped"
fi

say "MySQL"
if pgrep -x mysqld >/dev/null 2>&1 || pgrep -f mysqld_safe >/dev/null 2>&1; then
    # ⚠️ Il guardiano per primo. Uccidendo mysqld mentre mysqld_safe e' vivo,
    # ne parte subito un altro e sembra che MySQL non si fermi mai.
    if pgrep -f mysqld_safe >/dev/null 2>&1; then
        pkill -f mysqld_safe 2>/dev/null
        sleep 1
        ok "mysqld_safe stopped, nothing will restart it now"
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
pgrep -f mysqld_safe >/dev/null 2>&1 && still="$still mysqld_safe"

if [ -n "$still" ]; then
    fail "still running:$still"
    exit 1
fi
ok "everything is down"
