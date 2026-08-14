#!/usr/bin/env python3
"""Renames the control scripts inside a staged package.

The stack ships nineteen shell scripts under share/ plus the control script
next to them. They only talk to each other: the folder name, the library name
and the XAMPP_ROOT variable never leave that set, so renaming all of them
together is safe and self-contained. The compiled binaries are a different
story and are not touched here, they still carry their install path inside and
only a rebuild removes that.

Also installs the replacement for checkmysqlport. See the header of
Resources/stack-patches/checkmysqlport for why the original had to go.

Usage:
    python3 tools/brand-stack.py build/stack/vxostfiles
"""
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PATCHES = os.path.join(HERE, "Resources", "stack-patches")

# Order matters: the specific forms are replaced before the bare word, or
# "share/xampp" would already have become "share/vxost" halfway through and the
# more precise rules would find nothing.
RULES = [
    ("/Applications/XAMPP/xamppfiles", "/Applications/VXOST/vxostfiles"),
    ("share/xampp", "share/vxost"),
    ("xampplib", "vxostlib"),
    ("XAMPP_ROOT", "VXOST_ROOT"),
    ("XAMPP", "VXOST"),
    ("Xampp", "Vxost"),
    ("xampp", "vxost"),
]


def rewrite(path):
    """Applies the rules to one file. Returns how many replacements were made."""
    try:
        with open(path, encoding="utf-8", errors="surrogateescape") as handle:
            text = handle.read()
    except (OSError, UnicodeDecodeError):
        return 0

    original = text
    count = 0
    for old, new in RULES:
        count += text.count(old)
        text = text.replace(old, new)

    if text == original:
        return 0

    mode = os.stat(path).st_mode
    with open(path, "w", encoding="utf-8", errors="surrogateescape") as handle:
        handle.write(text)
    os.chmod(path, mode)
    return count


def checker_for(path):
    """The command that checks this file's syntax, or None if there is none.

    The interpreter comes from the shebang, not from the extension: share/
    holds shell scripts and at least one Perl script, and running sh -n on the
    Perl one reports a syntax error that is not there.
    """
    try:
        with open(path, "rb") as handle:
            first = handle.readline(200).decode("utf-8", "replace")
    except OSError:
        return None
    if not first.startswith("#!"):
        return None
    if "perl" in first:
        return ["/usr/bin/perl", "-c", path]
    if "php" in first:
        return None          # the stack's own php may not be runnable yet
    if "sh" in first:
        return ["/bin/sh", "-n", path]
    return None


def main():
    if len(sys.argv) < 2:
        print("usage: brand-stack.py <staged vxostfiles folder>", file=sys.stderr)
        return 2
    payload = sys.argv[1]

    share_old = os.path.join(payload, "share", "xampp")
    share_new = os.path.join(payload, "share", "vxost")
    if os.path.isdir(share_old):
        if os.path.isdir(share_new):
            shutil.rmtree(share_new)
        os.rename(share_old, share_new)
        print("    share/xampp -> share/vxost")

    # ⚠️ etc/xampp e' una CARTELLA DI STATO, non documentazione. Dentro ci sono
    # startssl, che dice ad Apache di partire con -DSSL, e rights_fixed, che
    # evita di rifare il controllo dei permessi a ogni avvio.
    #
    # Riscrivere il riferimento dentro lo script senza rinominare la cartella
    # e' peggio che non toccare niente: lo script cerca in etc/vxost, non trova
    # startssl, e Apache parte senza SSL. La porta 443 resta chiusa e https
    # smette di rispondere, senza un errore che lo dica. E' successo il 14/08.
    state_old = os.path.join(payload, "etc", "xampp")
    state_new = os.path.join(payload, "etc", "vxost")
    if os.path.isdir(state_old):
        if os.path.isdir(state_new):
            shutil.rmtree(state_new)
        os.rename(state_old, state_new)
        print("    etc/xampp -> etc/vxost  (startssl, rights_fixed)")

    lib_old = os.path.join(share_new, "xampplib")
    if os.path.isfile(lib_old):
        os.rename(lib_old, os.path.join(share_new, "vxostlib"))
        print("    xampplib -> vxostlib")

    targets = []
    control = os.path.join(payload, "vxost")
    if os.path.isfile(control):
        targets.append(control)
    for name in sorted(os.listdir(share_new)) if os.path.isdir(share_new) else []:
        targets.append(os.path.join(share_new, name))
    for name in ("properties.ini", "lampp"):
        path = os.path.join(payload, name)
        if os.path.isfile(path):
            targets.append(path)

    total = 0
    for path in targets:
        total += rewrite(path)
    print(f"    {total} references rewritten in {len(targets)} files")

    # ⚠️ fix_rights assegna tutta la cartella temp a daemon, e dentro c'e'
    # anche temp/mysql, che mysqld usa girando come _mysql. Dopo il passaggio
    # di fix_rights MySQL non riesce piu' a creare i file temporanei di InnoDB
    # e si rifiuta di partire, con "Unknown/unsupported storage engine: InnoDB".
    #
    # E' un difetto che arriva da monte, ma si vede solo quando fix_rights
    # gira, cioe' quando manca etc/vxost/rights_fixed. Vale la pena chiuderlo
    # qui invece di lasciarlo in agguato.
    rights = os.path.join(payload, "bin", "fix_rights")
    if os.path.isfile(rights):
        with open(rights, encoding="utf-8", errors="surrogateescape") as handle:
            text = handle.read()
        marker = "chown -R daemon:daemon ${BASEX}/temp"
        addition = marker + "\n# temp/mysql appartiene a mysqld, che gira come _mysql: senza questa riga\n# InnoDB non riesce a creare i suoi file temporanei e MySQL non parte.\nchown -R _mysql:_mysql ${BASEX}/temp/mysql 2>/dev/null"
        if marker in text and "temp/mysql" not in text:
            with open(rights, "w", encoding="utf-8", errors="surrogateescape") as handle:
                handle.write(text.replace(marker, addition, 1))
            print("    fix_rights patched, it no longer takes temp/mysql from MySQL")

    # ⚠️ La radice web nel pacchetto si chiama www, e gli script che la
    # nominano vanno con lei.
    #
    # fix_rights e' quello che conta: gira al primo avvio e assegna i permessi
    # partendo da ${BASEX}/htdocs, che nel pacchetto non esiste piu'. Non
    # rompe niente, ma stampa nove errori nel log di avvio automatico, e nove
    # errori all'avvio sono nove motivi per credere che qualcosa non vada.
    webroot_fixed = 0
    for folder in ("bin", "share"):
        base = os.path.join(payload, folder)
        for root, _dirs, files in os.walk(base):
            for name in files:
                path = os.path.join(root, name)
                if not checker_for(path) and not path.endswith("fix_rights"):
                    continue
                with open(path, encoding="utf-8", errors="surrogateescape") as handle:
                    text = handle.read()
                if "/htdocs" not in text:
                    continue
                with open(path, "w", encoding="utf-8", errors="surrogateescape") as handle:
                    handle.write(text.replace("/htdocs", "/www"))
                webroot_fixed += 1
    if webroot_fixed:
        print(f"    {webroot_fixed} files now point at www, not at the folder that no longer exists")

    # ⚠️ Dove mandare chi ha un problema.
    #
    # Due righe indicano ancora il forum e l'email di Apache Friends, e a chi
    # scrive da un prodotto che non e' il loro rispondono giustamente che non
    # e' roba loro. Sono istruzioni rivolte all'utente, non note di copyright:
    # queste si cambiano, quelle no.
    #
    # ⛔ Le righe "Copyright ... oswald@apachefriends.org" restano dove sono.
    # Sono l'attribuzione degli autori di codice GPL, e toglierla non e' una
    # ripulitura del marchio, e' una violazione della licenza.
    support = {
        os.path.join(share_new, "diagnose"): [
            ("http://www.apachefriends.org/f/", "https://vxost.com/faq/"),
            ("Please contact our forum", "See"),
        ],
        os.path.join(share_new, "backup.head"): [
            ("Please email to oswald@apachefriends.org for help.",
             "See https://vxost.com/faq/ for help."),
        ],
    }
    for path, pairs in support.items():
        if not os.path.isfile(path):
            continue
        with open(path, encoding="utf-8", errors="surrogateescape") as handle:
            text = handle.read()
        changed = text
        for old_text, new_text in pairs:
            changed = changed.replace(old_text, new_text)
        if changed != text:
            with open(path, "w", encoding="utf-8", errors="surrogateescape") as handle:
                handle.write(changed)
            print(f"    {os.path.basename(path)}: chi ha un problema ora viene mandato su vxost.com")

    # The replacement goes in after the rewrite: it is already written in the
    # new names and a second pass over it would do nothing but could only hurt.
    patch = os.path.join(PATCHES, "checkmysqlport")
    if os.path.isfile(patch) and os.path.isdir(share_new):
        shutil.copyfile(patch, os.path.join(share_new, "checkmysqlport"))
        os.chmod(os.path.join(share_new, "checkmysqlport"), 0o755)
        print("    checkmysqlport replaced, skip-networking cannot be set any more")

    # Nothing ships that the shell cannot parse.
    broken = []
    checked = 0
    for path in targets:
        command = checker_for(path)
        if not command:
            continue
        checked += 1
        result = subprocess.run(command, capture_output=True, text=True)
        if result.returncode != 0:
            broken.append((os.path.relpath(path, payload),
                           result.stderr.strip().split("\n")[0]))
    if broken:
        print("    scripts that no longer parse:")
        for where, why in broken:
            print(f"      {where}: {why}")
        return 1
    print(f"    {checked} scripts checked, all parse")

    # Ogni cartella che lo script si aspetta deve esistere davvero. Un
    # riferimento riscritto che punta nel vuoto non da' errore, cambia solo il
    # comportamento in silenzio.
    control_text = ""
    if os.path.isfile(control):
        with open(control, encoding="utf-8", errors="surrogateescape") as handle:
            control_text = handle.read()
    for expected in re.findall(r'\$VXOST_ROOT/([A-Za-z0-9_/.-]+)"', control_text):
        target = os.path.join(payload, expected)
        parent = os.path.dirname(target)
        if expected.count("/") <= 1 and not os.path.exists(target) and not os.path.exists(parent):
            print(f"    ⚠ the script points at {expected}, which is not there")

    leftovers = []
    for path in targets:
        try:
            with open(path, encoding="utf-8", errors="surrogateescape") as handle:
                if re.search(r"xampp", handle.read(), re.IGNORECASE):
                    leftovers.append(os.path.relpath(path, payload))
        except OSError:
            pass
    if leftovers:
        print("    ⚠ still mention the old name:")
        for where in leftovers:
            print(f"      {where}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
