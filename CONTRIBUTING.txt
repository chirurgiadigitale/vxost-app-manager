# Contributing

Thanks for looking. This document covers what the app is meant to be, how to
build it, and the decisions that are not obvious from reading the code.

## What this app is, and is not

It is a **local development environment app**. It exists to do two things: add
functions that help someone working with VXOST, and make the whole thing
pleasant to look at.

That boundary is deliberate, so some directions are closed:

- **No hourly rates, amounts, invoicing, or clients as entities.** Time
  tracking is there to know how many hours went into a project and to send an
  account of them. The moment a price appears, this becomes a business tool,
  and it is not one. The CSV exports hours in decimal precisely because the
  money side belongs elsewhere.
- **No cloud, no accounts, no telemetry.** The app makes no network request of
  its own. Everything it knows, it reads from the local machine.

Before proposing a feature, the question is: **does it help someone developing
locally?** If the answer is about administration or accounting, it is out of
scope.

## Building

You need macOS 13 or later and the Command Line Tools. **Xcode is not
required**, and neither is any package manager or dependency.

```sh
make          # builds build/VXOST.app
make run      # builds and launches
make install  # copies to /Applications/VXOST/
make strings  # regenerates the 15 Localizable.strings from the catalogue
make icon     # regenerates the icon from the logo
make dist     # produces .dmg, .zip and SHA256SUMS.txt
make clean
```

The build must stay free of warnings: `-Wall -Wextra` are on, and a warning is
treated as something to fix rather than to ignore.

### A note on Swift

The app is written in Objective-C, which may look like an odd choice in 2026.
The reason is practical: on the machine it was written on, the Command Line
Tools ship a Swift compiler older than the SDK, and `swiftc` fails on anything
that touches the standard library. AppKit with `clang` has no such problem, and
it also gives finer control over `NSPopover` than `MenuBarExtra` does. If you
have a working Swift toolchain, that is not a reason to rewrite anything.

## How it is put together

| File | Responsibility |
| --- | --- |
| `main.m` | entry point, application menu |
| `XPPaths` | every VXOST path, log list, configuration files |
| `XPTheme` | design tokens, shared with the dashboard; light and dark |
| `XPTaskRunner` | command execution; privileged ones through `osascript` |
| `XPService` | one service: process detection, ports, state |
| `XPServiceMonitor` | polling, 2s in the foreground and 8s in the background |
| `XPActions` | **every operation**, shared by the popover and the window |
| `XPVirtualHost` | parses `httpd-vhosts.conf`: port to project served |
| `XPGitInfo` | which repository a project belongs to |
| `XPTimeEntry` / `XPTracker` | time tracking, several projects at once |
| `XPReport` | exportable summaries of hours worked |
| `XPLayout` | right-to-left helpers for the hand-drawn rows |
| `XP*View` / `XP*WindowController` | the interface |

The app lives in the Dock **and** in the menu bar, and both offer the same
functions. So that they cannot drift apart, every operation lives in
`XPActions` and both views call into it; results travel as a notification, so a
command started from one updates the other. **A new function goes in
`XPActions`**, not in one of the two views.

## Decisions worth knowing before changing them

**Service state comes from `pgrep`, not from the PID files.**
`var/mysql/<host>.pid` is owned by `_mysql` with `rw-rw----` permissions, and a
normal user cannot read it. Using PID files would make MySQL look permanently
stopped.

**Listening ports are checked with a TCP probe, not with `lsof`.**
Run as a normal user, `lsof` cannot see processes owned by `root` and `daemon`,
so Apache and ProFTPD would appear to have no ports at all. A `connect()` on
loopback tells the truth without any privilege.

**Logs are read from the tail only, 256 KB at a time.**
MySQL's `.err` can grow past three gigabytes. Never load a log whole.

**Commented-out `<VirtualHost>` blocks are recognised, not skipped.**
A port that is missing when you expect it is exactly what needs explaining, so
the parser reads line by line and reports those blocks as disabled.

**Git metadata is read from the files, not by running `git`.**
`.git/HEAD` and `.git/config` are two small text files; spawning a process per
row on every redraw would cost far more. The search for `.git` walks up the
parents, because a virtual host usually points at a subfolder, and stops at
`htdocs` so a project cannot be credited with another one's repository.

**Privileged commands go through the native password prompt.**
`do shell script … with administrator privileges`, the same mechanism the
original manager used. Do not add a privileged helper or touch `sudoers`.
`security` and `backup` ask interactive questions, so they open in Terminal
instead of running silently.

**Elapsed time is not end minus start.** Pauses are subtracted, including one
that is still open, which must be counted up to the present or the clock would
keep running while paused. Sessions shorter than five seconds are discarded as
accidental clicks, a test written with three-second sessions will fail for
that reason, not because of a bug.

## Interface conventions

**The window is built with Auto Layout**, on nested stack views. A new section
is added to the stack with constraints, **never with explicit coordinates**.
Three things come for free that way: the content really widens at full screen,
longer labels in other languages find room, and right-to-left layouts are
mirrored by the system.

The rows that draw themselves (`XPServiceRowView`, `XPVHostRowView`,
`XPButton`) still use coordinates internally, and they must use the helpers in
`XPLayout`, `XPMirror()` and `XPNaturalParagraphStyle()`, or they will stay
the wrong way round in Urdu.

Colours come from `XPTheme` and match the dashboard's tokens. Do not hardcode a
colour; add a token if one is missing.

## Translations

The app ships in 15 languages. **Translations live in a single catalogue,
`tools/i18n/catalog.json`**, from which `make strings` generates the `.lproj`
bundles. The generated files must not be edited by hand: the next build
overwrites them.

The generator refuses to write if a language is missing a key, or if a format
specifier does not match the base language, a `%@` lost in translation breaks
formatting in that language alone, and that is the kind of bug that reaches
production.

**Messages must be whole sentences, never assembled from fragments.**
`"Starting %@…"` is one string. Building it as `"Starting"` + `"of"` + name
works in English and breaks the grammar of most other languages.

Adding a user-visible string means adding it to the catalogue in all fifteen
languages. If you cannot translate them all, say so in the pull request and
leave the English text in place for the missing ones.

## Tests

There is no test framework: the checks are small command line programs that
link the real sources and print what they verified. To run one:

```sh
clang -fobjc-arc -Wall -Isrc -framework Cocoa \
      -o /tmp/check tools/../src/XPVirtualHost.m src/XPPaths.m your_check.m
```

They cover the duration maths, parallel sessions, report generation and CSV
quoting, the virtual host parser and the repository detection.

⚠️ **The tracker checks write to the real data file** in
`~/Library/Application Support/it.equipedigitale.vxost/timesheet.json`, and
they interfere with each other if run back to back. Clear it between runs, and
save it first if it holds real hours.

The interface itself has to be checked by eye; nothing automated covers it.

## Distribution

The app is ad-hoc signed and not notarised, so macOS blocks it on first launch
and the user has to allow it from System Settings. Notarising would need a paid
Apple Developer account. Building from source avoids the block entirely.

## Commits

Explain **why**, not what, the diff already says what changed. Mention the
decision behind a change and the alternative that was rejected, so the next
person does not have to rediscover it.

## Licence

GNU GPL, the same terms as VXOST. By contributing you agree your work is
released under it.
