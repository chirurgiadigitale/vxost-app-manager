#!/bin/bash
# Fotografa i processi ogni 5s e tiene le ultime 6 istantanee (30 secondi).
# Quando la 3306 smette di rispondere, scrive tutto: cosi' si vede che cosa
# stava girando nei trenta secondi prima dello spegnimento.
#
# Non serve sudo: ps e nc bastano. Non tocca niente, scrive solo un file.
OUT="${TMPDIR:-/tmp}/vxost-mysql-culprit.log"
RING="${TMPDIR:-/tmp}/vxost-mysql-ring"
mkdir -p "$RING"
i=0
echo "$(date '+%F %T')  osservatore avviato" >> "$OUT"
while true; do
    if nc -z -w2 127.0.0.1 3306 2>/dev/null; then
        ps -axo pid,ppid,user,etime,command > "$RING/$((i % 6)).snap"
        date '+%F %T' > "$RING/$((i % 6)).time"
        i=$((i + 1))
    else
        {
            echo
            echo "=========================================================="
            echo "$(date '+%F %T')  MySQL NON risponde piu'"
            echo "=========================================================="
            for n in 0 1 2 3 4 5; do
                [ -f "$RING/$n.snap" ] || continue
                echo "--- istantanea $(cat "$RING/$n.time" 2>/dev/null) ---"
                grep -iE "mysql|vxost|httpd|artisan|php |claude" "$RING/$n.snap" | grep -v "grep -iE"
            done
        } >> "$OUT"
        echo "catturato, vedi $OUT"
        exit 0
    fi
    sleep 5
done
