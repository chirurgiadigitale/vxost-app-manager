# VXOST

A native replacement for `manager-osx.app` on macOS: a Dock and menu bar app
that starts, stops and watches over Apache, MySQL and ProFTPD.

The original manager is a BitRock InstallBuilder binary from 2018, shipped only
for `i386`, `ppc` and `x86_64`. It still works on Apple Silicon, but only
because macOS runs it through Rosetta 2, the bundle carries no `arm64` slice.
Launched from a native shell it exits immediately, because its launcher picks
the executable by reading `uname -p` and has no branch for `arm`.

It cannot be restyled either: the interface is compiled into the executable and
the only replaceable resource is the icon. Hence the rewrite, which also drops
the Rosetta dependency.

No external dependency, no third-party framework, no network request. Native
arm64 binary of about 200 KB.

## What it does

The app lives in two places at once, and both lead to the same functions: the
Dock icon opens the full window, the menu bar icon gives quick access without
leaving what you were doing.

**Menu bar**, three bars, one per service, filled in the service colour when
running and outlined when stopped. The state of the whole stack is readable
without opening anything.

**Window**, services, projects, control, links, tools and configuration files,
all reachable without digging through a menu. Opens from the Dock, from the
menu bar icon's context menu, or with ⌘0.

**Projects**, answers the question "who owns port 4002?". It reads the
`<VirtualHost>` blocks from `httpd-vhosts.conf` and shows the port, the project
being served and its state, with buttons to open it in the browser or in the
Finder. It tells three cases apart: listening, configured but Apache is not
answering, and commented out in the configuration, the last one being why an
expected port turns up closed, something you would otherwise only discover by
opening the file.

**Panel**, state, PID and listening ports for each service; start and stop
individually or all together; restart; reload a single service from the context
menu on its row.

**Logs**, system logs and per-virtual-host logs, with a text filter and
automatic refresh. It always reads only the tail of the file: MySQL's `.err` can
grow past 3 GB and loading it whole would freeze the app.

**More**, enable and disable SSL, security check, backup, quick access to the
configuration files.

## How it detects state

It does not use the PID files: `var/mysql/<host>.pid` is owned by `_mysql` with
`rw-rw----` permissions and a normal user cannot read it, so MySQL would always
look stopped. Instead:

| Information | Method | Why |
| --- | --- | --- |
| Service running | `pgrep -f <binary path>` | works without privileges, and the full path tells VXOST's httpd apart from a system Apache |
| Configured ports | parsing `httpd.conf`, `httpd-ssl.conf`, `my.cnf`, `proftpd.conf` | reflects the real configuration, virtual hosts included |
| Listening ports | `connect()` on `127.0.0.1` | `lsof` run as a normal user cannot see `root` and `daemon` processes, a TCP probe can |

## Privileges

Starting and stopping the services requires root. The app uses
`do shell script … with administrator privileges`, that is the native macOS
password prompt, the same mechanism as the original manager. It does not touch
`sudoers` and installs no privileged helper.

`security` and `backup` ask interactive questions, so they are opened in
Terminal rather than run silently.

## Languages

The app speaks the same 15 languages as the dashboard: English, Italian,
German, Spanish, French, Brazilian Portuguese, Romanian, Hungarian, Polish,
Russian, Turkish, Japanese, Simplified Chinese, Traditional Chinese and Urdu.
It follows the system language, with nothing to configure.

Translations do not live in fifteen files kept in sync by hand but in a single
catalogue, `tools/i18n/catalog.json`, from which `make strings` generates the
`.lproj` bundles. The generator refuses to write if a language is missing a key
or if a format specifier does not match the base language: a `%@` lost in
translation breaks formatting in that language alone, and that is the kind of
bug you otherwise find in production.

Messages are whole sentences, never assembled from fragments: "Starting %@…" is
a single string, because building it as "Starting" + "of" + name produces
broken grammar in most languages.

Urdu reads right to left. macOS mirrors interfaces built with Auto Layout on its
own, but these views place elements at explicit coordinates: the flip is done by
hand in `src/XPLayout.m`, and covers rows, buttons, indicators and text
alignment.

To try a language other than the system one:

```sh
defaults write it.equipedigitale.vxost AppleLanguages -array de
open -b it.equipedigitale.vxost
defaults delete it.equipedigitale.vxost AppleLanguages   # restore
```

## Icon

The icon is generated from the official VXOST logo, the same SVG the dashboard
uses, so the app and the web root show the same mark.

`tools/make-icon.m` renders it at every size macOS asks for, from 16 px to
1024 px. None of them is an upscale: macOS loads the SVG natively and each size
is drawn from the vector. The mark is clipped to the system icon shape, a
superellipse, not a rectangle with circular corners, with a shadow applied from
64 px upwards.

It regenerates itself when the logo changes, or with `make icon`.

## Installing

Download the `.dmg` from the releases page, open it and drag `VXOST.app` where
you prefer, `/Applications`, or `/Applications/VXOST` next to the rest of the
installation.

### macOS blocks it on first launch

The app is ad-hoc signed and not notarised by Apple, so Gatekeeper objects on
first launch with something like *"cannot be opened because Apple cannot check
it for malicious software"*. This is not a flaw in the app: it happens to any
program distributed without a 99 €/year Apple Developer subscription.

To authorise it once:

1. try opening it with a double click and dismiss the warning;
2. go to **System Settings → Privacy & Security**;
3. scroll to the bottom: *"VXOST was blocked"* appears, with an **Open Anyway**
   button;
4. confirm with your password.

From then on it launches normally.

Alternatively, from Terminal:

```sh
xattr -dr com.apple.quarantine /Applications/VXOST.app
```

Anyone who would rather not trust a binary can build from source: the result is
identical and hits no block at all.

## Requirements

macOS 13 or later, on Apple Silicon or Intel. Building needs only the Command
Line Tools; Xcode is not required.

## Build

```sh
make          # builds build/VXOST.app
make icon     # regenerates the icon from the logo
make strings  # regenerates the 15 Localizable.strings from the catalogue
make run      # builds and launches
make install  # copies to /Applications/VXOST/
make dist     # creates dist/ with .dmg, .zip and SHA256SUMS.txt
make clean
```

`make dist` produces the publishable packages. The zip archive is created with
`ditto`: a plain `zip` would lose the bundle metadata and invalidate the
signature.

## Licence

GNU GPL, the same terms as VXOST.
