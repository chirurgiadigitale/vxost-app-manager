#!/usr/bin/env python3
"""Checks a staged package for strings that must never be published.

Reads the forbidden strings from standard input, one per line, and walks the
staged folder once. Exits 0 if the package is clean, 1 if anything was found.

Two reasons this is not a loop of `grep -rl`:

1. Speed. One scan for seventy words instead of seventy scans of 900 MB. The
   old form took minutes and made the build feel broken.

2. Context. A forbidden string is not always a leak. The GitHub organisation
   appears in every repository address the product links to, and on this build
   machine a project folder carries that same name, so the folder name enters
   the list and the product's own source links get reported as private data.
   An occurrence that sits right after "github.com/" is the project's own
   address and is allowed; the same word anywhere else still fails the build.

Usage:
    printf '%s\n' "${FORBIDDEN[@]}" | python3 tools/verify-package.py build/stack
"""
import os
import sys

# Text that legitimately precedes an allowed occurrence.
#
# "www." and "it." are the author's own identity, which the product states in
# the open and does not hide: the About panel credits www.chirurgiadigitale.it,
# and the time tracker reads the old it.chirurgiadigitale.xampp folder to carry
# over data from before the rename. Both carry a company name that is also the
# name of a project folder on this build machine, which is why they end up on
# the forbidden list at all. A leak is that same word inside a path, a virtual
# host or a database name — not the signature the author puts on his own work.
ALLOWED_AFTER = (b"github.com/", b"www.", b"it.")

# Files larger than this are read in pieces. Nothing in the package should be
# anywhere near it, but a stray database or archive must not exhaust memory.
CHUNK = 8 * 1024 * 1024
OVERLAP = 256


def occurrences(haystack, needle):
    """Every position of needle in haystack."""
    start = 0
    while True:
        found = haystack.find(needle, start)
        if found < 0:
            return
        yield found
        start = found + 1


def is_whole_word(data, at, length):
    """True if the match is not sitting inside a longer word.

    A project called "zorme" matched inside "Boszormenyi", a surname in the
    SQLite manual page, and the build refused to package over it. A real leak
    is always delimited: a path has slashes around it, a hostname has dots, a
    sentence has spaces. Requiring that turns a whole class of false alarms
    off without weakening the check.
    """
    before = data[at - 1:at] if at > 0 else b""
    after = data[at + length:at + length + 1]
    return not (before.isalnum() or after.isalnum())


def leaks_in(data, words):
    """The forbidden words that appear in data outside an allowed context."""
    found = set()
    for word in words:
        for at in occurrences(data, word):
            if not is_whole_word(data, at, len(word)):
                continue
            if any(data[max(0, at - len(prefix)):at] == prefix
                   for prefix in ALLOWED_AFTER):
                continue
            found.add(word)
            break
    return found


def scan(path, words):
    try:
        size = os.path.getsize(path)
    except OSError:
        return set()

    found = set()
    try:
        with open(path, "rb") as handle:
            if size <= CHUNK:
                return leaks_in(handle.read().lower(), words)
            # Chunks overlap, so a word split across the boundary is still seen.
            tail = b""
            while True:
                block = handle.read(CHUNK)
                if not block:
                    break
                found |= leaks_in((tail + block).lower(), words)
                tail = block[-OVERLAP:]
    except OSError:
        return found
    return found


def main():
    if len(sys.argv) < 2:
        print("usage: verify-package.py <staged folder>", file=sys.stderr)
        return 2
    stage = sys.argv[1]

    words = []
    for line in sys.stdin:
        word = line.strip().lower()
        # Short words match ordinary text as substrings and would fail every
        # build on a false positive.
        if len(word) >= 5:
            words.append(word.encode("utf-8", "replace"))
    if not words:
        print("  no forbidden strings given, nothing checked", file=sys.stderr)
        return 0

    hits = {}
    files = 0
    for root, dirs, names in os.walk(stage):
        for name in names:
            path = os.path.join(root, name)
            if os.path.islink(path):
                continue
            files += 1
            for word in scan(path, words):
                hits.setdefault(word.decode("utf-8", "replace"), []).append(
                    os.path.relpath(path, stage))

    if not hits:
        print(f"  nothing found in {files} files")
        return 0

    for word in sorted(hits):
        print(f"  FOUND: {word}")
        for where in sorted(hits[word])[:3]:
            print(f"      {where}")
        if len(hits[word]) > 3:
            print(f"      and {len(hits[word]) - 3} more files")
    return 1


if __name__ == "__main__":
    sys.exit(main())
