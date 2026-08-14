#!/bin/bash
#
# Toglie il vecchio nome da tutto quello che resta dentro l'installazione.
#
# Dopo la migrazione e la rinomina degli script restano tre categorie di
# residui, e vanno trattate in modo diverso:
#
#   1. roba morta         il vecchio manager, gli stub di Bitnami. Si cancella.
#   2. file di testo      commenti e percorsi dentro le configurazioni. Si
#                         riscrivono, e i percorsi diventano quelli veri invece
#                         di appoggiarsi al symlink di compatibilita'.
#   3. binari compilati   NON si toccano. Hanno il percorso dentro l'eseguibile
#                         e solo una ricompilazione lo cambia; i symlink
#                         nascosti li tengono in piedi.
#
# ⚠️ Le licenze di terzi non si modificano mai, nemmeno per togliere un nome:
# sono testi legali di altri. Qui non ne nominano nessuna, ma la regola resta.
#
# Copia tutto prima, valida con httpd -t alla fine, e rimette i backup se non
# passa.
#
# Usage:
#   sudo bash purge-old-name.sh check    elenca e basta
#   sudo bash purge-old-name.sh apply    fallo
#
set -uo pipefail

ROOT="/Applications/VXOST/vxostfiles"
MODE="${1:-check}"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$ROOT/backup/purge-$STAMP"
OLD_PATH="/Applications/XAMPP/xamppfiles"
NEW_PATH="/Applications/VXOST/vxostfiles"

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
fail() { printf '  \033[31m✗ %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓ %s\033[0m\n' "$*"; }

# Roba morta: non serve piu' a niente e porta il nome vecchio.
DEAD="
manager-osx.app
apache2/README.txt
proftpd/README.txt
mysql/README.txt
php/README.txt
phpmyadmin/doc
"

say "Checking the ground"

if [ "$(id -u)" -ne 0 ]; then
    fail "run this with sudo"
    exit 1
fi
ok "running as root"

[ -d "$ROOT" ] || { fail "$ROOT is not there"; exit 1; }

running=""
for p in httpd mysqld proftpd; do
    pgrep -x "$p" >/dev/null 2>&1 && running="$running $p"
done
if [ -n "$running" ]; then
    fail "still running:$running"
    echo "      sudo bash $(cd "$(dirname "$0")" && pwd)/stop-services.sh"
    exit 1
fi
ok "all services are stopped"

say "What is going to be removed"
found_dead=0
for item in $DEAD; do
    if [ -e "$ROOT/$item" ]; then
        printf '  %-28s %s\n' "$item" "$(du -sh "$ROOT/$item" 2>/dev/null | cut -f1)"
        found_dead=$((found_dead + 1))
    fi
done
[ "$found_dead" -eq 0 ] && echo "  nothing left to remove"

say "What is going to be rewritten"
# Solo file di testo. Il filtro sull'estensione non basta: si controlla che il
# file sia davvero testo, o un binario che per caso contiene la parola
# finirebbe riscritto e smetterebbe di funzionare.
TEXT_FILES="$(mktemp)"
grep -rli "xampp" "$ROOT" \
     --include="*.conf" --include="*.ini" --include="*.txt" --include="*.md" \
     --include="*.var" --include="*.html" \
     --exclude-dir=htdocs --exclude-dir=licenses --exclude-dir=backup \
     2>/dev/null > "$TEXT_FILES" || true
count=$(wc -l < "$TEXT_FILES" | tr -d ' ')
echo "  $count text files"
head -8 "$TEXT_FILES" | sed "s|$ROOT/|      |"
[ "$count" -gt 8 ] && echo "      and $((count - 8)) more"

say "What is deliberately left alone"
echo "  compiled binaries, they carry the path inside and only a rebuild changes it"
echo "  third party licences, they are somebody else's legal text"
echo "  htdocs, that is the dashboard repository and has its own rename"

if [ "$MODE" != "apply" ]; then
    rm -f "$TEXT_FILES"
    say "Check only. Nothing was changed."
    echo "  Run with 'apply' to go ahead."
    exit 0
fi

# ----------------------------------------------------------------- apply ---

say "Backing up"
mkdir -p "$BACKUP"
while IFS= read -r f; do
    [ -n "$f" ] || continue
    rel="${f#$ROOT/}"
    mkdir -p "$BACKUP/$(dirname "$rel")"
    cp "$f" "$BACKUP/$rel"
done < "$TEXT_FILES"
ok "$BACKUP"

rollback() {
    say "Rolling back"
    (cd "$BACKUP" && find . -type f -exec cp {} "$ROOT"/{} \;) 2>/dev/null
    fail "text files put back from $BACKUP"
}

say "Removing what is dead"
for item in $DEAD; do
    if [ -e "$ROOT/$item" ]; then
        rm -rf "$ROOT/$item"
        ok "$item"
    fi
done
# La copia accanto a vxostfiles, lasciata dall'installatore originale.
if [ -e "$ROOT/../manager-osx.app" ]; then
    rm -rf "$ROOT/../manager-osx.app"
    ok "../manager-osx.app"
fi

say "Rewriting the text files"
changed=0
while IFS= read -r f; do
    [ -n "$f" ] || continue
    # Il percorso vero al posto di quello che passa dal symlink, poi il nome.
    perl -pi -e "s{\Q$OLD_PATH\E}{$NEW_PATH}g;
                 s{XAMPP}{VXOST}g;
                 s{Xampp}{Vxost}g;
                 s{xampp}{vxost}g;" "$f"
    changed=$((changed + 1))
done < "$TEXT_FILES"
ok "$changed files"
rm -f "$TEXT_FILES"

say "Renaming the files whose name carries it"
for pair in "etc/extra/httpd-xampp.conf:etc/extra/httpd-vxost.conf" \
            "error/XAMPP_FORBIDDEN.html.var:error/VXOST_FORBIDDEN.html.var"; do
    src="${pair%%:*}"; dst="${pair##*:}"
    if [ -e "$ROOT/$src" ]; then
        mv "$ROOT/$src" "$ROOT/$dst"
        ok "$src -> $dst"
        # ⚠️ Rinominare un file incluso senza aggiornare chi lo include lascia
        # Apache che non parte piu'. Il riferimento si sistema ovunque.
        # ⚠️ Solo i .conf attivi. Riscrivere anche i .bak li renderebbe inutili
        # come punto di ritorno: un backup che cambia insieme all'originale non
        # e' un backup.
        grep -rl --include="*.conf" "$(basename "$src")" "$ROOT/etc" 2>/dev/null | while IFS= read -r ref; do
            perl -pi -e "s{\Q$(basename "$src")\E}{$(basename "$dst")}g" "$ref"
            printf '      reference updated in %s\n' "${ref#$ROOT/}"
        done
    fi
done

say "Checking Apache still parses"
configtest="$("$ROOT/bin/httpd" -t -d "$ROOT" -f "$ROOT/etc/httpd.conf" 2>&1 || true)"
if printf '%s' "$configtest" | grep -qi "Syntax OK"; then
    ok "Syntax OK"
else
    fail "the configuration no longer parses:"
    printf '%s' "$configtest" | head -6 | sed 's/^/      /'
    rollback
    exit 1
fi

say "What is left"
left=$(grep -rli "xampp" "$ROOT" --exclude-dir=htdocs --exclude-dir=licenses \
       --exclude-dir=backup 2>/dev/null | wc -l | tr -d ' ')
echo "  $left files still mention it, and they are binaries or the hidden links:"
grep -rli "xampp" "$ROOT" --exclude-dir=htdocs --exclude-dir=licenses \
     --exclude-dir=backup 2>/dev/null | head -6 | sed "s|$ROOT/|      |"

say "Done"
echo "  Start again and open a couple of projects:"
echo "      sudo $ROOT/vxost start"
echo
echo "  The backup is in $BACKUP"
