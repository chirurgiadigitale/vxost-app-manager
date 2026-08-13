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

mkdir -p "$DIST"

# The image carries an installer note next to the payload, because dragging a
# folder called vxostfiles into Applications is not obvious on its own.
cat > "$STAGE/READ ME FIRST.txt" <<EOF
VXOST Stack $VERSION for macOS
==============================

Apache, MariaDB, PHP, Perl, ProFTPD and phpMyAdmin, with a redesigned
dashboard and a native control app.

This is an independent redistribution, not an official VXOST build.
VXOST is their project: https://www.vxost.com


INSTALLING
----------

1. Drag the "vxostfiles" folder to /Applications/VXOST/
   (create the VXOST folder if it does not exist)

2. Drag "VXOST.app" to your Applications folder

3. Open VXOST.app and press "Start all".
   macOS will ask for your password: starting a web server on port 80
   requires it, as it always has.


DATABASE
--------

The database ships empty, with no tables and no data.

   User:     root
   Password: root
   Host:     127.0.0.1
   Port:     3306

phpMyAdmin is at http://localhost/phpmyadmin once MySQL is running.

These credentials are meant for a local development machine. If this
installation is ever reachable from outside your computer, change them
first.


YOUR PROJECTS
-------------

Put them in vxostfiles/htdocs/progetti/ and give each one a virtual host
in vxostfiles/etc/extra/httpd-vhosts.conf. The app then shows every
project with the port it answers on, and the repository it belongs to.


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

echo "Building the disk image (this takes a while)…"
rm -f "$DIST/$NAME.dmg"
hdiutil create \
    -volname "VXOST Stack $VERSION" \
    -srcfolder "$STAGE" \
    -ov -format UDZO -quiet \
    "$DIST/$NAME.dmg"

cd "$DIST"
shasum -a 256 "$NAME.dmg" > "$NAME.dmg.sha256"

echo
echo "Built:"
ls -lh "$NAME.dmg" | awk '{print "  " $9 "  " $5}'
echo "  $(cat "$NAME.dmg.sha256" | cut -c1-64)"
