#!/usr/bin/env python3
"""Adds a ServerAlias to every active <VirtualHost> block in a config file.

Written as a parser and not as a regular expression on purpose. The obvious
one-liner,

    s{<VirtualHost[^>]*>.*?\\KServerName\\s+(\\S+)}{...}gs

adds the alias after a ServerName that sits inside a COMMENTED example block
too, which leaves a bare ServerAlias outside any virtual host and Apache
refuses to start with "ServerAlias not allowed here". That is not a
hypothetical: it happened on the first run against a copy of the real file,
where a commented example lives at line 84.

Reads and writes in place. Prints what it did. Running it twice changes
nothing, blocks that already carry the alias are left alone.

Usage:
    python3 add-server-alias.py virtualhost httpd-vhosts.conf [more.conf ...]
"""
import sys


def is_comment(line):
    return line.lstrip().startswith("#")


def add_alias(path, alias):
    with open(path, encoding="utf-8", errors="surrogateescape") as handle:
        lines = handle.readlines()

    out = []
    depth = 0
    block = []          # the lines of the block being read
    added = 0
    skipped = 0

    def flush_block():
        """Writes the block out, with the alias in if it needs one."""
        nonlocal added, skipped
        if not block:
            return

        has_alias = any(
            not is_comment(l) and l.split()[:2] == ["ServerAlias", alias]
            for l in block if l.split()
        )
        if has_alias:
            skipped += 1
            out.extend(block)
            return

        # After the first uncommented ServerName, so it reads the way a
        # handwritten one would.
        for i, line in enumerate(block):
            parts = line.split()
            if not is_comment(line) and parts and parts[0] == "ServerName":
                indent = line[:len(line) - len(line.lstrip())]
                block.insert(i + 1, f"{indent}ServerAlias {alias}\n")
                added += 1
                break
        else:
            # A block with no ServerName at all: the alias goes right after
            # the opening line, which is still valid.
            indent = "    "
            block.insert(1, f"{indent}ServerAlias {alias}\n")
            added += 1
        out.extend(block)

    for line in lines:
        stripped = line.strip().lower()
        if not is_comment(line) and stripped.startswith("<virtualhost"):
            depth += 1
            block = [line]
            continue
        if depth and not is_comment(line) and stripped.startswith("</virtualhost"):
            block.append(line)
            depth -= 1
            flush_block()
            block = []
            continue
        if depth:
            block.append(line)
        else:
            out.append(line)

    # An unclosed block: nothing is written, the file is left as it was.
    if depth:
        print(f"  {path}: a <VirtualHost> block is never closed, left untouched")
        return False

    with open(path, "w", encoding="utf-8", errors="surrogateescape") as handle:
        handle.writelines(out)
    print(f"  {path}: {added} blocks given the alias, {skipped} already had it")
    return True


def main():
    if len(sys.argv) < 3:
        print("usage: add-server-alias.py <alias> <file> [file ...]", file=sys.stderr)
        return 2
    alias = sys.argv[1]
    ok = True
    for path in sys.argv[2:]:
        try:
            ok = add_alias(path, alias) and ok
        except OSError as error:
            print(f"  {path}: {error}", file=sys.stderr)
            ok = False
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
