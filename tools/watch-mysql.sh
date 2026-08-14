#!/bin/bash
#
# Watches MySQL and writes down the moment it goes away, with what its own log
# said in the seconds around it.
#
# Exists because "it keeps falling" is a symptom, not a diagnosis, and the
# evidence needed to tell the two apart lives in a file that only root can
# read and that nobody is looking at when it happens.
#
# It distinguishes the two cases that look identical from outside:
#
#   - a CRASH leaves the pid file behind and writes a stack trace to the error
#     log. The process disappears while the file says it should still be there.
#   - a SHUTDOWN removes the pid file and the socket, and the log ends with a
#     normal shutdown line. Somebody, or something, asked it to stop.
#
# Run it with sudo, or it cannot read the error log and half the evidence is
# missing. Leave it running in a terminal and get on with your work.
#
# Usage:
#   sudo bash watch-mysql.sh              check every 10 seconds
#   sudo bash watch-mysql.sh 30           check every 30 seconds
#
set -uo pipefail

INTERVAL="${1:-10}"

ROOT=""
for _candidate in "/Applications/VXOST/vxostfiles" "/Applications/XAMPP/xamppfiles"; do
    [ -d "$_candidate" ] && { ROOT="$_candidate"; break; }
done
[ -n "$ROOT" ] || { echo "No installation found under /Applications." >&2; exit 1; }

DATADIR="$ROOT/var/mysql"
ERRLOG="$(ls -t "$DATADIR"/*.err 2>/dev/null | head -1)"
REPORT="${TMPDIR:-/tmp}/vxost-mysql-watch.log"

stamp() { date '+%Y-%m-%d %H:%M:%S'; }

say() {
    printf '%s  %s\n' "$(stamp)" "$*"
    printf '%s  %s\n' "$(stamp)" "$*" >> "$REPORT"
}

if [ "$(id -u)" -ne 0 ]; then
    echo "⚠️  Not running as root: the error log cannot be read and the report"
    echo "   will only say when it went, not why. Better: sudo bash $0"
    echo
fi

echo "Watching MySQL every ${INTERVAL}s. Ctrl-C to stop."
echo "  data directory: $DATADIR"
echo "  error log:      ${ERRLOG:-none found}"
echo "  report:         $REPORT"
echo

was_running=""
while true; do
    if pgrep -x mysqld >/dev/null 2>&1; then
        running="yes"
    else
        running="no"
    fi

    if [ -z "$was_running" ]; then
        say "starting to watch, MySQL is $( [ "$running" = yes ] && echo up || echo down )"

    elif [ "$was_running" = "yes" ] && [ "$running" = "no" ]; then
        say "──────────────────────────────────────────────"
        say "MySQL WENT DOWN"

        # Il file pid e' la prova che distingue un crash da un arresto.
        if ls "$DATADIR"/*.pid >/dev/null 2>&1; then
            say "  the pid file is still there: this looks like a CRASH"
        else
            say "  no pid file left: this looks like a DELIBERATE SHUTDOWN"
        fi
        if [ -S "$DATADIR/mysql.sock" ]; then
            say "  the socket is still there too, which points at a crash"
        fi

        if [ -n "$ERRLOG" ] && [ -r "$ERRLOG" ]; then
            say "  last lines of its own log:"
            tail -25 "$ERRLOG" | sed 's/^/      /' | tee -a "$REPORT"
        else
            say "  the error log is not readable, run this with sudo"
        fi

        # Chi era in giro nello stesso momento: uno script, un riavvio, l'app.
        say "  processes that could be responsible, right now:"
        ps -eo pid,user,etime,command 2>/dev/null \
            | grep -iE "xampp|vxost|mysql|build-stack" \
            | grep -v grep | head -8 | sed 's/^/      /' | tee -a "$REPORT"
        say "──────────────────────────────────────────────"

    elif [ "$was_running" = "no" ] && [ "$running" = "yes" ]; then
        say "MySQL came back up, pid $(pgrep -x mysqld | head -1)"
    fi

    was_running="$running"
    sleep "$INTERVAL"
done
