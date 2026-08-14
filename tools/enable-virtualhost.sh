#!/bin/bash
#
# Makes https://virtualhost answer, next to https://localhost.
#
# Three things are needed and none of them is optional:
#
#   1. a line in /etc/hosts, or the name does not resolve at all
#   2. ServerAlias on the virtual hosts, or Apache serves the default site
#   3. a certificate that covers the name, or the browser refuses the page
#
# ⚠️ Everything here is ADDITIVE. localhost keeps working exactly as before,
# and so does every project already configured. That is deliberate: switching
# the name and the links in one step means that if any of the three fails, the
# whole machine stops serving and it is not obvious which of the three broke.
# The links are switched afterwards, once this has been seen to work.
#
# Usage:
#   sudo bash enable-virtualhost.sh check    look only, change nothing
#   sudo bash enable-virtualhost.sh apply    do it
#
set -uo pipefail

NAME="virtualhost"
HERE="$(cd "$(dirname "$0")/.." && pwd)"

ROOT=""
for _candidate in "/Applications/VXOST/vxostfiles" "/Applications/XAMPP/xamppfiles"; do
    [ -d "$_candidate" ] && { ROOT="$_candidate"; break; }
done
[ -n "$ROOT" ] || { echo "No installation found under /Applications." >&2; exit 1; }

CONF="$ROOT/etc"
VHOSTS="$CONF/extra/httpd-vhosts.conf"
HTTPD="$CONF/httpd.conf"
CRT="$CONF/ssl.crt/server.crt"
KEY="$CONF/ssl.key/server.key"
MODE="${1:-check}"
STAMP="$(date +%Y%m%d-%H%M%S)"

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

# mkcert runs as the user, not as root: its certificate authority lives in the
# user's Library and root would create a second, untrusted one.
REAL_USER="${SUDO_USER:-$(stat -f '%Su' /dev/console)}"
if [ -z "$REAL_USER" ] || [ "$REAL_USER" = "root" ]; then
    fail "cannot tell which user to run mkcert as"
    exit 1
fi
ok "certificates will be issued as $REAL_USER"

MKCERT="$(sudo -u "$REAL_USER" bash -lc 'command -v mkcert' 2>/dev/null || true)"
if [ -z "$MKCERT" ]; then
    fail "mkcert is not installed. brew install mkcert"
    exit 1
fi
ok "mkcert at $MKCERT"

if grep -qE "^[^#]*[[:space:]]$NAME([[:space:]]|$)" /etc/hosts; then
    ok "/etc/hosts already resolves $NAME"
    HOSTS_DONE=1
else
    echo "  /etc/hosts does not resolve $NAME yet"
    HOSTS_DONE=0
fi

# grep -c stampa gia' 0 quando non trova niente, ed esce con 1: senza il
# `|| true` il ripiego aggiungeva un secondo zero e l'output diceva "0\n0".
aliases=$(grep -c "ServerAlias.*$NAME" "$VHOSTS" 2>/dev/null || true)
blocks=$(grep -c "^<VirtualHost" "$VHOSTS" 2>/dev/null || true)
echo "  $blocks virtual hosts, $aliases already carry the alias"

if openssl x509 -noout -ext subjectAltName -in "$CRT" 2>/dev/null | grep -q "DNS:$NAME"; then
    ok "the certificate already covers $NAME"
    CERT_DONE=1
else
    echo "  the certificate does not cover $NAME yet"
    CERT_DONE=0
fi

if [ "$MODE" != "apply" ]; then
    say "Check only. Nothing was changed."
    echo "  Run with 'apply' to go ahead."
    exit 0
fi

# ----------------------------------------------------------------- apply ---

say "Backing the configuration up"
cp /etc/hosts "/etc/hosts.vxost-$STAMP.bak"
cp "$VHOSTS" "$VHOSTS.vxost-$STAMP.bak"
cp "$HTTPD"  "$HTTPD.vxost-$STAMP.bak"
[ -f "$CRT" ] && cp "$CRT" "$CRT.vxost-$STAMP.bak"
[ -f "$KEY" ] && cp "$KEY" "$KEY.vxost-$STAMP.bak"
ok "copies made with $STAMP in the name"

rollback() {
    say "Rolling back"
    cp "/etc/hosts.vxost-$STAMP.bak" /etc/hosts
    cp "$VHOSTS.vxost-$STAMP.bak" "$VHOSTS"
    cp "$HTTPD.vxost-$STAMP.bak"  "$HTTPD"
    [ -f "$CRT.vxost-$STAMP.bak" ] && cp "$CRT.vxost-$STAMP.bak" "$CRT"
    [ -f "$KEY.vxost-$STAMP.bak" ] && cp "$KEY.vxost-$STAMP.bak" "$KEY"
    fail "put back as it was"
}

if [ "$HOSTS_DONE" -eq 0 ]; then
    say "Teaching the machine the name"
    printf '\n# VXOST\n127.0.0.1\t%s\n::1\t\t%s\n' "$NAME" "$NAME" >> /etc/hosts
    ok "/etc/hosts"
fi

say "Adding the alias to every virtual host"
# ⚠️ Not a regular expression. The obvious one-liner also matches a ServerName
# inside a COMMENTED example block and leaves a bare ServerAlias outside any
# virtual host, and Apache then refuses to start. That is not hypothetical, it
# happened on the first run against a copy of the real file. The parser in
# add-server-alias.py tracks the blocks properly and is safe to run twice.
#
# httpd.conf carries virtual hosts of its own on this machine, so both files.
if ! python3 "$HERE/tools/add-server-alias.py" "$NAME" "$VHOSTS" "$HTTPD"; then
    rollback
    exit 1
fi

if [ "$CERT_DONE" -eq 0 ]; then
    say "Issuing a certificate that covers both names"
    TMP="$(mktemp -d)"
    chown "$REAL_USER" "$TMP"

    # ⚠️ -H e CAROOT sono entrambi necessari, e la prima versione non li aveva.
    #
    # Questo script gira come root. Un `sudo -u utente` lanciato da root NON
    # riporta HOME a quella dell'utente, quindi mkcert cercava la propria
    # autorita' di certificazione in /var/root/Library e non la trovava; a quel
    # punto provava a crearne una nuova la' dentro, senza averne il permesso, e
    # falliva. Il controllo piu' sopra invece funzionava perche' usa `bash -lc`,
    # cioe' una shell di login, che HOME la imposta.
    #
    # -H la sistema, e CAROOT esplicito rende la cosa indipendente da come e'
    # configurato sudo su questa macchina.
    CAROOT="$(sudo -u "$REAL_USER" -H "$MKCERT" -CAROOT 2>/dev/null)"
    if [ -z "$CAROOT" ] || [ ! -d "$CAROOT" ]; then
        fail "cannot find the mkcert certificate authority for $REAL_USER"
        echo "      run 'mkcert -install' as $REAL_USER first"
        rm -rf "$TMP"
        rollback
        exit 1
    fi
    ok "certificate authority at $CAROOT"

    # localhost stays on the certificate: dropping it would break every link
    # that has not been switched yet, which at this point is all of them.
    #
    # ⚠️ The output is kept. The first version sent it to /dev/null and all the
    # failure said was "mkcert failed", which is the one thing that was already
    # obvious.
    if sudo -u "$REAL_USER" -H env CAROOT="$CAROOT" \
            "$MKCERT" -cert-file "$TMP/c.pem" -key-file "$TMP/k.pem" \
            "$NAME" localhost 127.0.0.1 ::1 > "$TMP/log" 2>&1; then
        # ⚠️ Il certificato si controlla PRIMA di installarlo.
        #
        # Con CAROOT sbagliato mkcert non fallisce: si stampa "Created a new
        # local CA" e continua. Il file esce, lo script direbbe che e' andata,
        # e il browser rifiuterebbe la pagina perche' quella nuova autorita'
        # non e' nel portachiavi. Un fallimento silenzioso e' peggio di un
        # errore, quindi qui si guarda cosa e' uscito davvero.
        if ! openssl x509 -noout -ext subjectAltName -in "$TMP/c.pem" 2>/dev/null \
             | grep -q "DNS:$NAME"; then
            fail "the certificate that came out does not cover $NAME"
            rm -rf "$TMP"
            rollback
            exit 1
        fi
        # ⚠️ Guardare il NOME dell'emittente non basta, ed e' stato provato:
        # una CA appena creata prende lo stesso nome di quella vera, perche'
        # mkcert lo compone da utente e macchina. Le due sono indistinguibili a
        # leggerle. L'unica prova che vale e' matematica: il certificato deve
        # verificarsi contro la radice che sta gia' nel portachiavi.
        if ! openssl verify -CAfile "$CAROOT/rootCA.pem" "$TMP/c.pem" >/dev/null 2>&1; then
            fail "the certificate does not verify against the authority in your keychain"
            echo "      it was signed by a different one, and the browser would refuse it"
            echo "      authority checked: $CAROOT/rootCA.pem"
            rm -rf "$TMP"
            rollback
            exit 1
        fi

        cp "$TMP/c.pem" "$CRT"
        cp "$TMP/k.pem" "$KEY"
        chmod 644 "$CRT"; chmod 600 "$KEY"
        rm -rf "$TMP"
        ok "$NAME, localhost, 127.0.0.1, ::1"
        ok "signed by the authority already in your keychain"
    else
        fail "mkcert failed, this is what it said:"
        sed 's/^/      /' "$TMP/log"
        rm -rf "$TMP"
        rollback
        exit 1
    fi
fi

say "Checking the configuration"
if "$ROOT/bin/httpd" -t -d "$ROOT" -f "$HTTPD" 2>&1 \
     | tee /tmp/vxost-virtualhost-configtest.log | grep -qi "Syntax OK"; then
    ok "Syntax OK"
else
    cat /tmp/vxost-virtualhost-configtest.log
    rollback
    exit 1
fi

say "Done"
echo "  Restart Apache and try both, they must both answer:"
echo "      sudo $ROOT/xampp restartapache 2>/dev/null || sudo $ROOT/vxost restartapache"
echo "      curl -sI https://$NAME/dashboard/ | head -1"
echo "      curl -sI https://localhost/dashboard/ | head -1"
echo
echo "  Only once both answer are the links switched over."
