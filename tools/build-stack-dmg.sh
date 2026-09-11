#!/bin/bash
#
# Packages the staged stack into a distributable disk image.
#
# Run tools/build-stack.sh first: it is that script that decides what goes in
# and, more importantly, what stays out.
#
# Usage: bash tools/build-stack-dmg.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
STAGE="$HERE/build/stack"
DIST="$HERE/dist"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$HERE/Resources/Info.plist")"
NAME="VXOST-Stack-$VERSION"

[ -d "$STAGE/vxostfiles" ] || { echo "Nothing staged. Run tools/build-stack.sh first." >&2; exit 1; }

# ⚠️ Esistere non basta (rilievo G). Uno staging c'e' anche quando
# build-stack.sh e' morto a meta', quando e' di ieri, o quando qualcuno ci ha
# messo le mani dopo i controlli: in tutti e tre i casi il disco esce uguale,
# e nessuno se ne accorge finche' non lo installa.
#
# ⚠️ E nemmeno le date bastano. Il primo controllo era `find -newer` sul
# timbro, e si aggira senza volerlo: si cambia un file, si rimette la data di
# prima con `touch -t`, e non trova niente. Qui si confronta il CONTENUTO con
# il manifesto scritto da build-stack.sh, che elenca impronta, dimensione,
# permessi e bersagli dei link. Si verifica anche la versione: uno staging
# della release precedente non diventa il disco di questa.
STAMP="$STAGE/.verified"
MANIFEST="$STAGE/.verified.manifest"
if [ ! -f "$STAMP" ] || [ ! -f "$MANIFEST" ]; then
    echo "The staging was never verified (no $STAMP): build-stack.sh did not finish. Run it again." >&2
    exit 1
fi

_stamped_version="$(sed -n 's/^version=//p' "$STAMP")"
if [ "$_stamped_version" != "$VERSION" ]; then
    echo "The staging is version ${_stamped_version:-unknown}, this disk would say $VERSION: run build-stack.sh again." >&2
    exit 1
fi

# Il manifesto stesso puo' essere stato riscritto: la sua impronta sta nel
# timbro, e si controlla prima di credergli.
_stamped_manifest="$(sed -n 's/^manifest=//p' "$STAMP")"
_now_manifest="$(shasum -a 256 "$MANIFEST" | cut -d" " -f1)"
if [ "$_stamped_manifest" != "$_now_manifest" ]; then
    echo "The manifest does not match the stamp: one of the two was rewritten. Run build-stack.sh again." >&2
    exit 1
fi

# ⚠️ In sola lettura: il confronto non tocca lo staging verificato.
if ! python3 "$HERE/tools/stage-manifest.py" "$STAGE" --confronta "$MANIFEST"; then
    echo "The staging changed after it was verified: run build-stack.sh again." >&2
    exit 1
fi
echo "Staging verified on $(sed -n 's/^date=//p' "$STAMP"), $(sed -n 's/^files=//p' "$STAMP") entries unchanged"

mkdir -p "$DIST"

# The layout folder is built first so that the installer note goes there and
# not into the staging, which must stay exactly as it was verified.
LAYOUT="$HERE/build/dmg-layout"
rm -rf "$LAYOUT"
mkdir -p "$LAYOUT/VXOST"

# The image carries an installer note next to the payload, because dragging a
# folder called vxostfiles into Applications is not obvious on its own.
cat > "$LAYOUT/READ ME FIRST.txt" <<EOF
VXOST Stack $VERSION for macOS
==============================

Apache, MariaDB, PHP, Perl, ProFTPD and phpMyAdmin, with a redesigned
dashboard and a native control app.

A project of Equipe Digitale, released under the GNU GPL v2.
https://www.vxost.com


INSTALLING
----------

On this disk there are two things to install and an Applications shortcut
to drop them on.

1. Drag the "VXOST" folder onto "Applications".
   That is the server itself: Apache, the database, PHP.

2. Drag "VXOST.app" onto "Applications" as well.
   That is the app you will open every day. Two separate things on
   purpose: the app appears in Launchpad and Spotlight, the server
   folder does not clutter them.

3. Open VXOST from Launchpad and press "Start all".
   macOS will ask for your password: starting a web server on port 80
   requires it, as it always has.

4. macOS will also say it cannot verify the developer, and refuse to
   open it. This is expected and it is not a sign that anything is
   wrong: the app is signed but not notarised, which needs a paid
   Apple account. Open System Settings > Privacy & Security, scroll to
   the bottom, and press "Open anyway". Once only.

If you already have XAMPP, stop it before starting VXOST: they both
want port 80 and port 3306, and two servers on the same port give an
error that explains nothing. There is a guide for moving across at
https://vxost.com/guides/


DATABASE
--------

The database ships empty, with no tables and no data.

   User:     root
   Password: root
   Host:     127.0.0.1
   Port:     3306

phpMyAdmin is at https://virtualhost/phpmyadmin once MySQL is running.

These credentials are meant for a local development machine. If this
installation is ever reachable from outside your computer, change them
first.


YOUR PROJECTS
-------------

Press "New project" in the app: give it a name, optionally the address
of a GitHub repository, and a port. VXOST creates the folder, writes the
virtual host and restarts Apache.

You can still do it by hand. Put the project in vxostfiles/www/projects/
and add a virtual host in vxostfiles/etc/extra/httpd-vhosts.conf, with a
matching "Listen" line in vxostfiles/etc/httpd.conf. The app then shows
every project with the port it answers on, and the repository it belongs to.


FIRST LAUNCH
------------

macOS blocks applications that are not notarised by Apple. Open
System Settings, then Privacy & Security, scroll to the bottom and
choose "Open Anyway".


LICENCE
-------

GNU GPL, the same terms as VXOST. Every bundled component keeps its own
licence; see vxostfiles/licenses/.
EOF

# 🔴 La cartella si prepara gia' fatta, e si mette un alias ad Applications.
#
# Prima il disco conteneva "vxostfiles" sciolta, e il READ ME diceva di
# trascinarla in /Applications/VXOST/ "creando la cartella VXOST se non
# esiste". Nel Finder quella frase non si puo' eseguire: non si trascina
# dentro una cartella che non c'e', e crearla in /Applications chiede la
# password di amministratore prima ancora di cominciare.
#
# Davide si e' bloccato li' il 21/08/2026, sul suo secondo Mac, seguendo le
# nostre stesse istruzioni. Chi scarica e non ha nessuno a cui chiedere
# chiude il disco e se ne va.
#
# Adesso sul disco c'e' una cartella "VXOST" gia' pronta con dentro
# vxostfiles, e accanto un alias a /Applications: si trascina la cartella
# sull'alias, come in qualsiasi altro programma per macOS. Nessun percorso da
# scrivere, nessuna cartella da creare.
echo "Laying out the disk image"
# ditto e non cp: conserva i permessi, i link e i metadati dei bundle, che una
# copia normale perderebbe insieme alla firma dell'app.
ditto "$STAGE/vxostfiles" "$LAYOUT/VXOST/vxostfiles"
ditto "$STAGE/VXOST.app" "$LAYOUT/VXOST.app"
ln -s /Applications "$LAYOUT/Applications"

echo "Building the disk image (this takes a while)…"
rm -f "$DIST/$NAME.dmg"
hdiutil create \
    -volname "VXOST Stack $VERSION" \
    -srcfolder "$LAYOUT" \
    -ov -format UDZO -quiet \
    "$DIST/$NAME.dmg"
rm -rf "$LAYOUT"

cd "$DIST"
shasum -a 256 "$NAME.dmg" > "$NAME.dmg.sha256"

echo
echo "Built:"
ls -lh "$NAME.dmg" | awk '{print "  " $9 "  " $5}'
echo "  $(cat "$NAME.dmg.sha256" | cut -c1-64)"
