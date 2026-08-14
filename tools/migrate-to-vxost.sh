#!/bin/bash
#
# Moves the stack from /Applications/XAMPP to /Applications/VXOST.
#
# The binaries are not relocatable: httpd, php, mysqld, proftpd and perl carry
# their install path compiled in, and 119 configuration files repeat it. So the
# folder is renamed and two hidden symlinks are left behind, which keep every
# one of those paths resolving. The old name survives on disk, hidden, until
# the stack is recompiled.
#
# Nothing is deleted. If the configuration fails to parse afterwards the whole
# thing is put back exactly as it was.
#
# Usage:
#   sudo bash migrate-vxost.sh check    look only, change nothing
#   sudo bash migrate-vxost.sh apply    do it
#
set -uo pipefail

OLD="/Applications/XAMPP"
NEW="/Applications/VXOST"
OLD_FILES="xamppfiles"
NEW_FILES="vxostfiles"
ROOT="$NEW/$NEW_FILES"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
APP_SRC="$HERE/build/VXOST.app"
PATCH_SRC="$HERE/Resources/stack-patches/checkmysqlport"
MODE="${1:-check}"

# Convenience links that live next to xamppfiles and point inside it.
LINKS="bin cgi-bin etc htdocs logs manager-osx.app"

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

if [ -L "$OLD" ]; then
    ok "$OLD is already a symlink, the migration has run before"
    exit 0
fi

if [ ! -d "$OLD" ]; then
    fail "$OLD is not there, nothing to migrate"
    exit 1
fi

if [ -e "$NEW" ]; then
    fail "$NEW already exists. Move it aside first, this script will not overwrite it."
    exit 1
fi

running=""
for p in httpd mysqld proftpd; do
    pgrep -x "$p" >/dev/null 2>&1 && running="$running $p"
done
if [ -n "$running" ]; then
    fail "still running:$running"
    echo "      sudo $OLD/$OLD_FILES/xampp stop"
    exit 1
fi
ok "all services are stopped"

refs=$(grep -rl "$OLD/$OLD_FILES" "$OLD/$OLD_FILES/etc" 2>/dev/null | wc -l | tr -d ' ')
ok "$refs configuration files mention the old path, the symlinks will cover them"

if [ -d "$APP_SRC" ]; then
    ok "app to install: $APP_SRC"
else
    echo "  (no app bundle at $APP_SRC, it will be skipped)"
fi

if [ "$MODE" != "apply" ]; then
    say "Check only. Nothing was changed."
    echo "  Run with 'apply' to go ahead."
    exit 0
fi

# ----------------------------------------------------------- the rollback ---

rollback() {
    say "Rolling back"
    [ -L "$OLD" ] && rm -f "$OLD"
    [ -L "$NEW/$OLD_FILES" ] && rm -f "$NEW/$OLD_FILES"
    if [ -d "$NEW/$NEW_FILES" ]; then
        mv "$NEW/$NEW_FILES" "$NEW/$OLD_FILES"
        for l in $LINKS; do
            [ -L "$NEW/$l" ] && rm -f "$NEW/$l" && ln -s "$OLD_FILES/$l" "$NEW/$l"
        done
    fi
    [ -d "$NEW" ] && [ ! -e "$OLD" ] && mv "$NEW" "$OLD"
    fail "put back as it was"
}

# ----------------------------------------------------------------- apply ---

say "Renaming the folder"
mv "$OLD" "$NEW" || { fail "rename failed"; exit 1; }
ok "XAMPP -> VXOST"

say "Renaming xamppfiles"
mv "$NEW/$OLD_FILES" "$NEW/$NEW_FILES" || { rollback; exit 1; }
ok "xamppfiles -> vxostfiles"

say "Repointing the internal links"
for l in $LINKS; do
    if [ -L "$NEW/$l" ]; then
        rm -f "$NEW/$l"
        ln -s "$NEW_FILES/$l" "$NEW/$l"
        printf '  %s -> %s/%s\n' "$l" "$NEW_FILES" "$l"
    fi
done

say "Leaving the compatibility links, hidden"
# The compiled-in paths and the 119 config files still say XAMPP. These two
# links are what keeps them resolving. Both are hidden from the Finder.
ln -s "$NEW_FILES" "$NEW/$OLD_FILES" || { rollback; exit 1; }
ln -s "$NEW" "$OLD"                  || { rollback; exit 1; }
chflags -h hidden "$OLD" 2>/dev/null
chflags -h hidden "$NEW/$OLD_FILES" 2>/dev/null
ok "$OLD -> $NEW"
ok "$NEW/$OLD_FILES -> $NEW_FILES"

say "Checking the configuration"
if "$ROOT/bin/httpd" -t -d "$ROOT" -f "$ROOT/etc/httpd.conf" 2>&1 \
     | tee /tmp/vxost-migrate-configtest.log | grep -qi "Syntax OK"; then
    ok "Syntax OK"
else
    cat /tmp/vxost-migrate-configtest.log
    rollback
    exit 1
fi

say "Installing the app"
# In /Applications, not inside the stack folder: the original manager lived
# under /Applications/XAMPP/ and anyone not used to it never found the thing.
# At the top level it behaves like any other application, Launchpad lists it
# and Spotlight suggests it.
if [ -d "$APP_SRC" ]; then
    rm -rf "$NEW/XAMPP.app" "$NEW/VXOST.app" "/Applications/VXOST.app"
    cp -R "$APP_SRC" "/Applications/VXOST.app"
    chown -R root:admin "/Applications/VXOST.app"
    ok "/Applications/VXOST.app"
else
    echo "  skipped"
fi

say "Making the security check safe to run"
# ⚠️ The stock check offers to add skip-networking to my.cnf, with yes as the
# default answer. On 05/08/2026 that answer was taken and every project that
# connects to 127.0.0.1:3306 stopped working. The replacement offers the thing
# that was actually wanted, bind-address on loopback, and can undo the damage.
if [ -f "$PATCH_SRC" ]; then
    cp "$PATCH_SRC" "$ROOT/share/xampp/checkmysqlport"
    chmod 755 "$ROOT/share/xampp/checkmysqlport"
    # The live installation still uses the old variable and folder names, so
    # the replacement is adjusted to them rather than the other way round.
    perl -pi -e 's{VXOST_ROOT}{XAMPP_ROOT}g; s{share/vxost}{share/xampp}g;
                  s{vxostlib}{xampplib}g; s{\$XAMPP_ROOT/vxost }{\$XAMPP_ROOT/xampp }g' \
             "$ROOT/share/xampp/checkmysqlport"
    /bin/sh -n "$ROOT/share/xampp/checkmysqlport" && ok "checkmysqlport replaced"
else
    echo "  patch not found at $PATCH_SRC, skipped"
fi

if [ -f "$ROOT/etc/my.cnf" ] && ! grep -qE '^[[:space:]]*bind-address' "$ROOT/etc/my.cnf"; then
    cp "$ROOT/etc/my.cnf" "$ROOT/etc/my.cnf.vxost-$(date +%Y%m%d-%H%M%S).bak"
    perl -pi -e 'if (/^\[mysqld\]/ && !$done) {
        $_ .= "\n# Reachable from this computer only. Do not replace this with\n";
        $_ .= "# skip-networking, which would cut off every project that\n";
        $_ .= "# connects to 127.0.0.1:3306.\n";
        $_ .= "bind-address=127.0.0.1\n";
        $done = 1;
    }' "$ROOT/etc/my.cnf"
    ok "MySQL restricted to 127.0.0.1, projects keep working"
else
    echo "  my.cnf already has a bind-address, left alone"
fi

say "Done"
echo "  Start the services and open a couple of projects before trusting it:"
echo "      sudo $ROOT/xampp start"
echo
echo "  What you will see in /Applications: one folder, VXOST."
echo "  The old name is still there as a hidden symlink. To see it:"
echo "      ls -laO /Applications | grep -i xampp"
