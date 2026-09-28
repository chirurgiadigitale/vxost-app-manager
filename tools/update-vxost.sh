#!/bin/bash
# Aggiorna un'installazione di VXOST con il pacchetto che sta accanto a questo
# script, sul disco del DMG. Si lancia una volta, come amministratore:
#
#   sudo bash "/Volumes/VXOST Stack <versione>/Update an existing VXOST.sh"
#
# Perche' uno script e non una guida da incollare (17 e 28/09/2026): i passi
# erano righe protette da `[ ... ] &&`, e un `!` incollato davanti le ha
# rovesciate, cancellando il database vivo di un secondo Mac. Qui non c'e'
# niente da incollare riga per riga, e ogni controllo ferma lo script invece
# di stampare un messaggio.
#
# Regole, in ordine di importanza:
#   1. Tutti i controlli PRIMA di toccare qualsiasi cosa.
#   2. Mai rm. La vecchia installazione si sposta di fianco con un nome che
#      contiene data e ora, e non puo' collidere con niente.
#   3. MariaDB non si ferma mai con KILL: se non si ferma da sola, lo script
#      si ferma e non tocca niente.
#   4. Progetti e database si COPIANO nella nuova installazione: la vecchia
#      resta intera finche' non la si cancella a mano, e tornare indietro e'
#      spostare due cartelle.
#
# Per le prove: VXOST_APPS sostituisce /Applications, e VXOST_UPDATE_SANDBOX=1
# salta il controllo di root e la chiusura dell'app. Non servono ad altro.

set -euo pipefail

APPS="${VXOST_APPS:-/Applications}"
SANDBOX="${VXOST_UPDATE_SANDBOX:-}"
# Solo per le prove: quanto aspettare MariaDB. Tre minuti di default.
DBWAIT="${VXOST_UPDATE_DB_WAIT:-180}"
SRC="$(cd "$(dirname "$0")" && pwd)"
OLD="$APPS/VXOST"
STAMP="$(date '+%Y%m%d-%H%M%S')"
BACKUP="$APPS/VXOST-old-$STAMP"
MARKER=".vxost-update"

say()  { printf '%s\n' "$*"; }
stop() {
	printf '\nSTOPPED: %s\n' "$*" >&2
	printf 'Your installation was not changed. If VXOST was stopped, start it again from the app.\n' >&2
	exit 1
}

# --- 1. Controlli. Niente e' stato toccato finche' non finiscono. ------------

say "VXOST update"
say ""

if [ -z "$SANDBOX" ] && [ "$(id -u)" -ne 0 ]; then
	stop "run it with sudo: sudo bash \"$0\""
fi

[ -d "$SRC/VXOST/vxostfiles" ] || stop "the new VXOST folder is not next to this script ($SRC)."
[ -d "$SRC/VXOST.app" ]        || stop "VXOST.app is not next to this script ($SRC)."
NEWVER=$(defaults read "$SRC/VXOST.app/Contents/Info" CFBundleShortVersionString 2>/dev/null) \
	|| stop "cannot read the version of the new VXOST.app."

case "$SRC/" in
	"$OLD"/*) stop "this script must run from the disk image, not from inside $OLD." ;;
esac

if [ ! -e "$OLD" ]; then
	stop "there is no VXOST in $APPS to update. For a new installation, drag the VXOST folder and VXOST.app onto Applications."
fi
[ -L "$OLD" ] && stop "$OLD is a symbolic link. Update it by hand, or ask for help."
[ -d "$OLD/vxostfiles/var/mysql" ] || stop "$OLD/vxostfiles/var/mysql is missing: this does not look like a VXOST installation."

if [ -f "$OLD/vxostfiles/$MARKER" ] && [ "$(cat "$OLD/vxostfiles/$MARKER")" = "$NEWVER" ]; then
	say "VXOST $NEWVER is already installed and was updated by this script. Nothing to do."
	exit 0
fi

[ -e "$BACKUP" ] && stop "$BACKUP already exists. Wait one second and run the script again."

# I progetti stanno in www/projects o, sulle installazioni vecchie, in
# www/progetti. Tutte e due piene vuol dire due versioni degli stessi file, e
# quale sia quella buona lo sa solo chi ci lavora.
pieno() { [ -d "$1" ] && [ -n "$(ls -A "$1" 2>/dev/null | grep -vxE 'index\.php|\.htaccess|\.DS_Store' || true)" ]; }
# ⚠️ Si ricorda il NOME della cartella, non il percorso: la vecchia
# installazione verra' spostata, e un percorso calcolato adesso puntera' a una
# cartella che non c'e' piu'. La prima versione copiava cosi' zero progetti e
# diceva "Done".
PROJNAME=""
if pieno "$OLD/vxostfiles/www/projects" && pieno "$OLD/vxostfiles/www/progetti"; then
	stop "both www/projects and www/progetti contain projects. Merge them by hand into one folder, then run this again."
elif pieno "$OLD/vxostfiles/www/projects"; then
	PROJNAME=projects
elif pieno "$OLD/vxostfiles/www/progetti"; then
	PROJNAME=progetti
fi

# Spazio: la nuova installazione, piu' una copia del database e dei progetti.
kb() { du -sk "$1" 2>/dev/null | awk '{print $1}'; }
need=$(( $(kb "$SRC/VXOST") + $(kb "$SRC/VXOST.app") + $(kb "$OLD/vxostfiles/var/mysql") ))
[ -n "$PROJNAME" ] && need=$(( need + $(kb "$OLD/vxostfiles/www/$PROJNAME") ))
need=$(( need + need / 10 ))
free=$(df -k "$APPS" | awk 'NR==2 {print $4}')
[ "$free" -gt "$need" ] || stop "not enough free disk space: about $((need / 1024)) MB are needed, $((free / 1024)) MB are free."

say "Updating $OLD to VXOST $NEWVER."
say "The current installation will be kept, untouched, in $BACKUP."
[ -n "$PROJNAME" ] && say "Projects: $OLD/vxostfiles/www/$PROJNAME"
say ""

# --- 2. Fermare i servizi, e verificarlo. -----------------------------------

# I nostri processi: il comando comincia con la nostra radice, oppure e' uno
# script (mysqld_safe) lanciato da una shell con la nostra radice come primo
# argomento. In ps uno script si chiama sh, non con il suo nome.
ours() {
	local elenco
	elenco=$(ps -axo pid=,command=) || return 1
	printf '%s\n' "$elenco" | awk -v r="$OLD/vxostfiles/" -v me="$$" '
		{
			if (match($0, /^[ \t]*[0-9]+[ \t]/) == 0) next
			pid = $1; cmd = substr($0, RSTART + RLENGTH)
			if (pid == me) next
			if (index(cmd, r) == 1) { print pid " " cmd; next }
			sp = index(cmd, " "); if (sp == 0) next
			inter = substr(cmd, 1, sp - 1); sub(/^.*\//, "", inter)
			if ((inter == "sh" || inter == "bash") && index(substr(cmd, sp + 1), r) == 1) print pid " " cmd
		}'
}
# ⚠️ Un elenco che non si legge non e' un elenco vuoto: vuoto vorrebbe dire
# "tutto fermo", e si andrebbe avanti con MariaDB accesa.
pids_matching() {
	local elenco
	elenco=$(ours) || stop "cannot read the process list, so whether VXOST is running is unknown."
	printf '%s\n' "$elenco" | awk -v s="$1" 'index($0, s) { print $1 }'
}
# Tutti i nostri tranne il database e il suo supervisore, che hanno regole loro.
pids_others() {
	local elenco
	elenco=$(ours) || stop "cannot read the process list, so whether VXOST is running is unknown."
	printf '%s\n' "$elenco" | awk 'NF && !index($0, "/sbin/mysqld") && !index($0, "/bin/mysqld_safe") { print $1 }'
}

say "Stopping VXOST..."
if [ -z "$SANDBOX" ]; then
	osascript -e 'quit app "VXOST"' >/dev/null 2>&1 || true
fi

# Il supervisore per primo: ignora TERM e rigenera il database.
for p in $(pids_matching "/bin/mysqld_safe"); do kill -9 "$p" 2>/dev/null || true; done

# MariaDB: arresto ordinato, e si aspetta. Un database grande puo' metterci.
for p in $(pids_matching "/sbin/mysqld"); do kill -TERM "$p" 2>/dev/null || true; done
i=0
while [ -n "$(pids_matching "/sbin/mysqld")" ] && [ $i -lt "$DBWAIT" ]; do sleep 1; i=$((i + 1)); done
if [ -n "$(pids_matching "/sbin/mysqld")" ]; then
	stop "MariaDB did not stop within 3 minutes, and it is never forced: a database killed in the middle of a write can be damaged. Stop it from VXOST, or restart the Mac, then run this again."
fi

# Il resto (Apache, ProFTPD e altri): TERM, e dopo 20 secondi KILL. Non
# tengono dati aperti.
#
# ⛔ MariaDB e' esclusa da questo ciclo: qui arriva gia' ferma, e se un
# mysqld fosse nato nel frattempo, il KILL qui sotto lo prenderebbe.
for p in $(pids_others); do kill -TERM "$p" 2>/dev/null || true; done
i=0
while [ -n "$(pids_others)" ] && [ $i -lt 20 ]; do sleep 1; i=$((i + 1)); done
for p in $(pids_others); do kill -9 "$p" 2>/dev/null || true; done
sleep 1
rimasti=$(ours) || stop "cannot read the process list, so whether VXOST is still running is unknown."
[ -z "$rimasti" ] || stop "these VXOST processes are still running:
$rimasti"
say "  all VXOST services are stopped."

# --- 3. Da qui in poi si cambia qualcosa. -----------------------------------

# Se qualcosa va storto a meta', si rimette tutto come prima: la nuova
# installazione incompleta si sposta di lato (mai cancellata), la vecchia
# torna al suo posto.
spostata=0
ripristina() {
	local e=$?
	[ $e -eq 0 ] && return
	[ $spostata -eq 1 ] || exit $e
	printf '\nSomething failed. Putting the previous installation back...\n' >&2
	mkdir -p "$APPS/VXOST-incomplete-$STAMP" 2>/dev/null || true
	if [ -e "$OLD" ]; then mv "$OLD" "$APPS/VXOST-incomplete-$STAMP/VXOST" 2>/dev/null || true; fi
	if [ -e "$BACKUP/VXOST.app.previous" ]; then
		[ -e "$APPS/VXOST.app" ] && mv "$APPS/VXOST.app" "$APPS/VXOST-incomplete-$STAMP/VXOST.app" 2>/dev/null
		mv "$BACKUP/VXOST.app.previous" "$APPS/VXOST.app" 2>/dev/null || true
	fi
	if mv "$BACKUP" "$OLD" 2>/dev/null; then
		printf 'Your previous VXOST is back in %s. The incomplete copy is in %s.\n' "$OLD" "$APPS/VXOST-incomplete-$STAMP" >&2
	else
		printf 'Could not move it back: your previous VXOST is intact in %s.\n' "$BACKUP" >&2
	fi
	exit $e
}
trap ripristina EXIT

say "Keeping the current installation aside..."
mv "$OLD" "$BACKUP"
spostata=1
printf 'VXOST installation kept by the update to %s on %s\n' "$NEWVER" "$(date)" > "$BACKUP/KEPT-BY-UPDATE.txt"

say "Installing VXOST $NEWVER..."
ditto "$SRC/VXOST" "$OLD"
if [ -e "$APPS/VXOST.app" ]; then
	mv "$APPS/VXOST.app" "$BACKUP/VXOST.app.previous"
fi
ditto "$SRC/VXOST.app" "$APPS/VXOST.app"

NEW="$OLD/vxostfiles"
KEPT="$BACKUP/vxostfiles"

say "Copying your databases..."
mv "$NEW/var/mysql" "$NEW/var/mysql.from-package-$STAMP"
ditto "$KEPT/var/mysql" "$NEW/var/mysql"
# File di esecuzione del server fermo: il pid di un processo che non c'e'
# farebbe credere a mysql.server che MariaDB giri ancora.
rm -f "$NEW/var/mysql/"*.pid "$NEW/var/mysql/mysql.sock" "$NEW/var/mysql/mysql.sock.lock"

if [ -n "$PROJNAME" ]; then
	say "Copying your projects..."
	PROJ="$KEPT/www/$PROJNAME"
	mkdir -p "$NEW/www/projects"
	copiati=0
	# ⚠️ index.php e .htaccess in cima alla cartella sono della dashboard, non
	# dei progetti: copiandoli, quelli vecchi sostituirebbero i nuovi.
	for voce in "$PROJ"/* "$PROJ"/.[!.]*; do
		[ -e "$voce" ] || continue
		nome=$(basename "$voce")
		case "$nome" in index.php|.htaccess|.DS_Store) continue ;; esac
		ditto "$voce" "$NEW/www/projects/$nome"
		copiati=$((copiati + 1))
	done
	# Una cartella che all'inizio aveva progetti e da cui non si copia niente
	# e' un errore, non un'installazione senza progetti.
	[ $copiati -gt 0 ] || { echo "no project was copied from $PROJ" >&2; false; }
	say "  $copiati copied."
fi

# La radice delle installazioni di partenza, che i virtual host piu' vecchi
# nominano ancora. Composta a pezzi: il nome non deve comparire nel pacchetto.
RADICE_A_MONTE="/Applications/XA""MPP/xa""mppfiles"
VH_OLD="$KEPT/etc/extra/httpd-vhosts.conf"
VH_NEW="$NEW/etc/extra/httpd-vhosts.conf"
if [ -f "$VH_OLD" ]; then
	say "Bringing back your virtual hosts..."
	[ -f "$VH_NEW" ] && mv "$VH_NEW" "$VH_NEW.from-package-$STAMP"
	sed -e "s#$RADICE_A_MONTE#$APPS/VXOST/vxostfiles#g" \
	    -e "s#/Applications/VXOST/vxostfiles#$APPS/VXOST/vxostfiles#g" \
	    -e "s#$APPS/VXOST/vxostfiles/htdocs#$APPS/VXOST/vxostfiles/www#g" \
	    -e "s#$APPS/VXOST/vxostfiles/www/progetti#$APPS/VXOST/vxostfiles/www/projects#g" \
	    "$VH_OLD" > "$VH_NEW"
fi

# Le porte dei progetti: solo quelle che mancano, e solo su questo Mac, come
# il resto del pacchetto. Rilanciato non duplica niente.
if [ -f "$KEPT/etc/httpd.conf" ]; then
	porte=$(awk '/^[ \t]*Listen[ \t]/ { p = $2; sub(/^.*:/, "", p); if (p ~ /^[0-9]+$/ && p != 80 && p != 443) print p }' "$KEPT/etc/httpd.conf" | sort -un)
	aggiunte=""
	for p in $porte; do
		if ! awk -v p="$p" '/^[ \t]*Listen[ \t]/ { q = $2; sub(/^.*:/, "", q); if (q == p) f = 1 } END { exit !f }' "$NEW/etc/httpd.conf"; then
			printf 'Listen 127.0.0.1:%s\n' "$p" >> "$NEW/etc/httpd.conf"
			aggiunte="$aggiunte $p"
		fi
	done
	[ -n "$aggiunte" ] && say "Ports reopened on this Mac:$aggiunte"
	vh_in_conf=$(grep -c '^[[:space:]]*<VirtualHost' "$KEPT/etc/httpd.conf" || true)
fi

printf '%s\n' "$NEWVER" > "$NEW/$MARKER"
trap - EXIT

# --- 4. Avvio. ---------------------------------------------------------------

say ""
if [ -z "$SANDBOX" ]; then
	say "Starting VXOST..."
	"$NEW/vxost" start || say "Some services did not start: open VXOST to see which, and why."
fi

say ""
say "Done. VXOST $NEWVER is installed, with your projects and databases."
say ""
say "Your previous installation is untouched in:"
say "  $BACKUP"
say "Delete it only when everything works."
if [ "${vh_in_conf:-0}" -gt 0 ]; then
	say ""
	say "Note: your old httpd.conf had $vh_in_conf virtual host(s) written directly in it."
	say "They were not copied. They are in $KEPT/etc/httpd.conf"
fi
say "Changes you made by hand to php.ini or my.cnf are not copied either:"
say "the old files are in $KEPT/etc/"
say ""
say "To go back: quit VXOST and stop the servers, then in Terminal:"
say "  sudo mv \"$OLD\" \"$APPS/VXOST-new-$STAMP\""
say "  sudo mv \"$BACKUP\" \"$OLD\""
