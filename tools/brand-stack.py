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
