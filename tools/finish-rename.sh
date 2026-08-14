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
echo "  control script: $CONTROL"

# ⚠️ Il nome non basta per dire che il lavoro e' fatto. Dopo un ripristino
# andato a meta' il file puo' chiamarsi vxost e contenere ancora lo script
# originale: uscire qui lascerebbe il lavoro a meta' senza dirlo.
if ! grep -q "XAMPP_ROOT" "$ROOT/$CONTROL" 2>/dev/null; then
    ok "already renamed inside as well, nothing to do"
    exit 0
fi

leftovers=$(grep -rli "xampp" "$ROOT/share/xampp" "$ROOT/$CONTROL" 2>/dev/null | wc -l | tr -d ' ')
echo "  $leftovers files still carry the old name"

if [ "$MODE" != "apply" ]; then
    say "Check only. Nothing was changed."
    echo "  Run with 'apply' to go ahead."
    exit 0
fi

# --- l'avvio automatico va sospeso mentre si lavora ------------------------
#
# ⚠️ Il LaunchDaemon installato dalla migrazione ha RunAtLoad, e launchd
# rilancia un lavoro che esce male. Il 14/08 ha acceso i servizi nel mezzo
# della rinomina, mentre lo script stava spostando file: lo stop diceva di
# aver funzionato e un istante dopo Apache era di nuovo su.
#
# Un lavoro di manutenzione lo sospende all'inizio e lo rimette alla fine.
PLIST="/Library/LaunchDaemons/com.equipedigitale.vxost.plist"

suspend_autostart() {
    [ -f "$PLIST" ] || return 0
    if launchctl list 2>/dev/null | grep -q "com.equipedigitale.vxost"; then
        launchctl unload -w "$PLIST" 2>/dev/null
        ok "autostart suspended while we work"
        AUTOSTART_WAS_ON=1
    fi
}

resume_autostart() {
    [ -f "$PLIST" ] || return 0
    [ "${AUTOSTART_WAS_ON:-0}" = "1" ] || return 0
    launchctl load -w "$PLIST" 2>/dev/null
    ok "autostart back on"
}

AUTOSTART_WAS_ON=0

# ----------------------------------------------------------------- apply ---

say "Suspending the autostart"
suspend_autostart

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
    # Se il nome di partenza era gia' vxost, il file va rimesso li' e non
    # cancellato: cancellarlo lascerebbe l'installazione senza script.
    [ "$CONTROL" = "vxost" ] || rm -f "$ROOT/vxost"
    rm -rf "$ROOT/share/vxost" "$ROOT/share/vxost-control-panel"
    tar -xf "$BACKUP/share.tar" -C "$ROOT/share" 2>/dev/null
    # ⚠️ Il symlink va tolto PRIMA della copia. cp segue i collegamenti: senza
    # questa riga scrive dentro vxost invece che al posto del symlink, e il
    # ripristino lascia i due nomi incrociati. E' successo.
    rm -f "$ROOT/$CONTROL"
    cp "$BACKUP/$CONTROL" "$ROOT/$CONTROL"
    chmod 755 "$ROOT/$CONTROL"
    resume_autostart
    fail "put back as it was, from $BACKUP"
}

say "Renaming the control script"
# ⚠️ Il file puo' gia' chiamarsi vxost e contenere ancora l'originale: e' lo
# stato in cui lascia un ripristino andato a meta'. In quel caso non c'e'
# niente da rinominare, solo il contenuto da riscrivere, e un `mv` di un file
# su se stesso fallirebbe.
LEGACY="xampp"
if [ "$CONTROL" != "vxost" ]; then
    mv "$ROOT/$CONTROL" "$ROOT/vxost" || { rollback; exit 1; }
    LEGACY="$CONTROL"
    ok "$CONTROL -> vxost"
else
    ok "already named vxost, only the contents need rewriting"
fi
chmod 755 "$ROOT/vxost"

# Un eventuale symlink al vecchio nome va tolto ora: piu' avanti va ricreato,
# e nel frattempo un `cp` che lo seguisse scriverebbe dentro vxost.
[ -L "$ROOT/$LEGACY" ] && rm -f "$ROOT/$LEGACY"

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
ln -s "vxost" "$ROOT/$LEGACY" 2>/dev/null
chflags -h hidden "$ROOT/$LEGACY" 2>/dev/null
ok "$LEGACY -> vxost, hidden"

say "Checking it actually works"
# ⚠️ Non basta che il file esista: deve rispondere. Un rinominatore che
# sbaglia una variabile lascia uno script che parte e non fa niente, e ce ne
# si accorgerebbe solo al primo avvio dei servizi.
# ⚠️ L'uscita si cattura, non si mette in pipe.
#
# Con `set -o pipefail` una pipe vale quanto il comando piu' a sinistra che
# fallisce, quindi `script | grep -q parola` risulta fallito anche quando la
# parola c'e', se lo script esce con codice diverso da zero. E questo script
# esce diverso da zero: lanciato da root fa un controllo dei permessi su file
# che non esistono piu' e se ne lamenta. La rinomina era riuscita ed e' stata
# annullata da questo, non da un problema vero.
#
# Si usa un'azione inesistente e non nessuna azione: il risultato e' lo stesso
# elenco di comandi, ma e' esplicito che non si vuole eseguire niente.
answer="$("$ROOT/vxost" --vxost-selfcheck 2>&1 || true)"
if printf '%s' "$answer" | grep -qi "usage"; then
    ok "vxost answers"
else
    fail "the renamed script does not answer as expected"
    printf '%s' "$answer" | head -8 | sed 's/^/      /'
    rollback
    exit 1
fi

configtest="$("$ROOT/bin/httpd" -t -d "$ROOT" -f "$ROOT/etc/httpd.conf" 2>&1 || true)"
if printf '%s' "$configtest" | grep -qi "Syntax OK"; then
    ok "Apache configuration still parses"
else
    fail "the Apache configuration no longer parses"
    printf '%s' "$configtest" | head -5 | sed 's/^/      /'
    rollback
    exit 1
fi

leftover=$(grep -rli "xampp" "$ROOT/vxost" "$ROOT/share/vxost" 2>/dev/null | wc -l | tr -d ' ')
if [ "$leftover" -eq 0 ]; then
    ok "no script carries the old name any more"
else
    echo "  $leftover files still mention it, not fatal:"
    grep -rli "xampp" "$ROOT/vxost" "$ROOT/share/vxost" 2>/dev/null \
        | sed "s|$ROOT/|      |"
fi

resume_autostart

say "Done"
echo "  From now on:"
echo "      sudo $ROOT/vxost start"
echo
echo "  The backup is in $BACKUP if anything looks wrong."
