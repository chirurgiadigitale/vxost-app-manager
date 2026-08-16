#!/bin/bash
#
# La seconda fase: il nome dei virtual host diventa virtualhost.
#
# `enable-virtualhost.sh` era additivo di proposito: aggiungeva
# `ServerAlias virtualhost` e lasciava stare `ServerName localhost`, cosi' se
# qualcosa fosse andato storto la macchina continuava a servire. Ha funzionato,
# e adesso si chiude il cerchio.
#
# Perche' non basta l'alias: l'alias fa arrivare le richieste, il ServerName e'
# il nome con cui il server si presenta. Finche' resta `localhost`, la
# dashboard che legge la configurazione continua a mostrare il nome vecchio.
#
# ⚠️ Una correzione a un'ipotesi sbagliata, per non ripeterla. Il 15/08 avevo
# scritto qui che era Apache a rimettere `localhost` nei redirect. Non e' vero:
# con UseCanonicalName spento, che e' il default, Apache costruisce i redirect
# dall'intestazione Host della richiesta, non dal ServerName. Il redirect che
# si vedeva sulla porta 4000 lo scriveva **WordPress**, che lo firma con
# `X-Redirect-By`, e prendeva il nome da un WP_HOME scritto a mano nel
# wp-config.php di quel progetto. Vedi il controllo in fondo.
#
# ⚠️ Le righe commentate non si toccano. In httpd.conf c'e'
# `#ServerName www.example.com:@@Port@@`, che e' documentazione: la stessa
# trappola per cui il ServerAlias non si aggiunge con una regex. I blocchi
# commentati vengono elencati alla fine, perche' li si guardi a mano.
#
# Usage:
#   sudo bash finish-virtualhost.sh check
#   sudo bash finish-virtualhost.sh apply
#
set -uo pipefail

ACTION="${1:-check}"

ROOT=""
for _candidate in "/Applications/VXOST/vxostfiles" "/Applications/XAMPP/xamppfiles"; do
    [ -d "$_candidate" ] && { ROOT="$_candidate"; break; }
done
[ -n "$ROOT" ] || { echo "Nessuna installazione sotto /Applications." >&2; exit 1; }

HTTPD="$ROOT/etc/httpd.conf"
VHOSTS="$ROOT/etc/extra/httpd-vhosts.conf"
SSL="$ROOT/etc/extra/httpd-ssl.conf"
FILES=("$HTTPD" "$VHOSTS")
[ -f "$SSL" ] && FILES+=("$SSL")

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
fail() { printf '  \033[31m✗ %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓ %s\033[0m\n' "$*"; }
note() { printf '  %s\n' "$*"; }

if [ "$(id -u)" -ne 0 ]; then
    fail "va lanciato con sudo"
    exit 1
fi

# ---------------------------------------------------------------- ricognizione

say "Cosa c'e' adesso"

live=0
commented=0
for f in "${FILES[@]}"; do
    [ -f "$f" ] || continue
    n=$(grep -cE '^[[:space:]]*ServerName[[:space:]]+localhost[[:space:]]*$' "$f" 2>/dev/null || true)
    c=$(grep -cE '^[[:space:]]*#[[:space:]]*ServerName[[:space:]]+localhost[[:space:]]*$' "$f" 2>/dev/null || true)
    live=$((live + n))
    commented=$((commented + c))
    [ "$n" -gt 0 ] && note "$(basename "$f"): $n ServerName localhost da cambiare"
    [ "$c" -gt 0 ] && note "$(basename "$f"): $c commentati, lasciati come sono"
done

if [ "$live" -eq 0 ]; then
    ok "nessun ServerName localhost: e' gia' fatto"
    exit 0
fi

# ⚠️ Il nome deve risolvere PRIMA di metterlo in un ServerName. Se /etc/hosts
# non lo conosce, Apache riparte lo stesso ma il browser non arriva.
if grep -qE '^[^#]*[[:space:]]virtualhost([[:space:]]|$)' /etc/hosts; then
    ok "/etc/hosts risolve virtualhost"
else
    fail "/etc/hosts non risolve virtualhost: prima enable-virtualhost.sh"
    exit 1
fi

# Due blocchi sulla stessa porta con lo stesso nome: il secondo non serve mai.
say "Blocchi doppi sulla stessa porta"
dupes="$(grep -hoE '<VirtualHost[^>]*:[0-9]+>' "${FILES[@]}" 2>/dev/null \
         | grep -oE ':[0-9]+' | sort | uniq -d | tr -d ':')"
if [ -n "$dupes" ]; then
    for p in $dupes; do
        fail "porta $p: piu' di un <VirtualHost>, risponde solo il primo che Apache legge"
    done
    note "non e' un problema di questo script, ma va saputo"
else
    ok "una porta, un blocco"
fi

if [ "$ACTION" != "apply" ]; then
    say "Solo controllo. Non e' stato cambiato niente."
    note "Per procedere: sudo bash $0 apply"
    exit 0
fi

# --------------------------------------------------------------------- backup

STAMP="$(date +%Y%m%d-%H%M%S)"
say "Copie di sicurezza"
for f in "${FILES[@]}"; do
    [ -f "$f" ] || continue
    cp "$f" "$f.vxost-$STAMP.bak" || { fail "copia di $f fallita"; exit 1; }
done
ok "con $STAMP nel nome"

# ------------------------------------------------------------------- riscrittura

say "Riscrittura"
for f in "${FILES[@]}"; do
    [ -f "$f" ] || continue
    # Solo le righe vive, e solo quelle che dicono esattamente
    # "ServerName localhost": una riga con un commento in coda o un nome
    # diverso non viene toccata.
    perl -pi -e 's{^(\s*)ServerName\s+localhost\s*$}{$1ServerName virtualhost\n}' "$f"
    # L'alias diventa superfluo: era il ponte, e il ponte ha finito.
    perl -pi -e 's{^(\s*)ServerAlias\s+virtualhost\s*$}{}' "$f"
done
ok "ServerName virtualhost, e via l'alias che serviva a fare il ponte"

# ------------------------------------------------------------------ validazione

say "Controllo della configurazione"
output="$("$ROOT/bin/httpd" -t -d "$ROOT" -f "$HTTPD" 2>&1)"
if printf '%s' "$output" | grep -qi 'Syntax OK'; then
    ok "Syntax OK"
else
    fail "Apache non e' d'accordo, rimetto tutto com'era:"
    printf '%s\n' "$output" | head -6 | sed 's/^/      /'
    for f in "${FILES[@]}"; do
        [ -f "$f.vxost-$STAMP.bak" ] && cp "$f.vxost-$STAMP.bak" "$f"
    done
    exit 1
fi

# --------------------------------------------------------------------- riavvio

say "Riavvio"
# ⚠️ apachectl -k restart e non lo script di controllo: lo script decide
# guardando un file pid e sa dire "already running" senza aver fatto niente.
if pgrep -x httpd >/dev/null 2>&1; then
    "$ROOT/bin/apachectl" -k restart >/dev/null 2>&1
else
    "$ROOT/bin/apachectl" -k start >/dev/null 2>&1
fi
i=0
while [ $i -lt 15 ] && ! pgrep -x httpd >/dev/null 2>&1; do sleep 1; i=$((i + 1)); done
pgrep -x httpd >/dev/null 2>&1 && ok "Apache gira" || fail "Apache non e' ripartito"

# ------------------------------------------------------------------- verifica

say "Prova dal vivo"
code="$(curl -sI -m 6 -o /dev/null -w '%{http_code}' https://virtualhost/dashboard/ 2>/dev/null || echo 000)"
[ "$code" = "200" ] && ok "https://virtualhost/dashboard/ risponde $code" \
                     || fail "https://virtualhost/dashboard/ risponde $code"

# Il motivo per cui esiste questo script: il redirect non deve piu' nominare
# il nome vecchio.
#
# ⚠️ E se lo nomina, non e' detto che sia colpa di Apache. Un progetto puo'
# generare il proprio redirect: WordPress lo fa, e lo firma con
# `X-Redirect-By: WordPress`. Su questa macchina il 16/08 la porta 4000
# rimandava a http://localhost:4000/ con il ServerName gia' cambiato, perche'
# nel wp-config.php c'era WP_HOME scritto a mano.
#
# Dare la colpa alla configurazione di Apache sarebbe stato mandare qualcuno a
# cercare per ore nel file sbagliato. Quindi si guarda chi ha firmato.
for p in $(grep -hoE '^[[:space:]]*Listen[[:space:]]+[0-9.]*:?([0-9]+)' "$HTTPD" \
           | grep -oE '[0-9]+$' | grep -v '^80$' | head -5); do
    head="$(curl -sI -m 6 "http://127.0.0.1:$p/" 2>/dev/null)"
    target="$(printf '%s' "$head" | grep -i '^Location:' | sed 's/^[Ll]ocation:[[:space:]]*//' | tr -d '\r')"
    by="$(printf '%s' "$head" | grep -i '^X-Redirect-By:' | sed 's/^[^:]*:[[:space:]]*//' | tr -d '\r')"

    case "$target" in
        "")
            ok "porta $p: nessun redirect"
            ;;
        *localhost*)
            if [ -n "$by" ]; then
                note "porta $p rimanda a $target, ma lo scrive $by, non Apache"
                note "   → e' la configurazione di quel progetto, non la nostra"
            else
                fail "la porta $p rimanda ancora a $target, e lo scrive Apache"
            fi
            ;;
        *)
            ok "porta $p rimanda a $target"
            ;;
    esac
done

say "Fatto"
note "Le copie sono accanto ai file, con $STAMP nel nome."
if [ "$commented" -gt 0 ]; then
    note ""
    note "⚠️ $commented ServerName localhost sono dentro blocchi commentati e non"
    note "   sono stati toccati. Sono progetti spenti: si sistemano quando si"
    note "   riaccendono. Per vederli:"
    note "      grep -n '#.*ServerName localhost' $VHOSTS $HTTPD"
fi
