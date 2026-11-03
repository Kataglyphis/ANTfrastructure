"""Minimum package versions for the ELF version nodes a bundle needs from a host package, read from Debian symbols files.

Version nodes only: a symbol with no node, as in GLib, and per-symbol minimums are out. docs/python-app-bundles.md#versioned-host-dependencies"""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

INFO_DIR = Path("/var/lib/dpkg/info")
SYMBOL = re.compile(r' (?:\([^)]*\))?("[^"]+"|\S+) (\S+)(?: \d+)?')
Table = dict[str, tuple[str, dict[str, set[str]]]]


def parse_symbols(text: str, origin: str) -> Table:
    """{soname: (dependency template, {version node: package versions})}; an unreadable line fails the scan."""
    table: Table = {}
    current = ""
    for line in text.splitlines():
        if not line or line[0] in "|*#":
            continue
        if line[0] != " ":
            parts = line.split(None, 1)
            if len(parts) != 2:
                raise ValueError(f"malformed symbols header in {origin}: {line!r}")
            current = parts[0]
            table[current] = (parts[1], {})
            continue
        match = SYMBOL.fullmatch(line)
        if match is None or not current:
            raise ValueError(f"malformed symbols line in {origin}: {line!r}")
        node = match.group(1).strip('"').rpartition("@")[2] if "@" in match.group(1) else ""
        if node and node != "Base":
            table[current][1].setdefault(node, set()).add(match.group(2))
    return table


def version_newer(left: str, right: str) -> bool:
    """dpkg's own order, since epochs and tildes decide it."""
    result = subprocess.run(["dpkg", "--compare-versions", left, "gt", right], capture_output=True, check=False)
    if result.returncode not in (0, 1):
        raise ValueError(f"dpkg cannot compare {left} and {right}")
    return result.returncode == 0


def newest(versions: set[str]) -> str:
    best = ""
    for version in sorted(versions):
        if not best or version_newer(version, best):
            best = version
    return best


def oldest(versions: set[str]) -> str:
    best = ""
    for version in sorted(versions):
        if not best or version_newer(best, version):
            best = version
    return best


def symbols_file(owner: str) -> Path | None:
    """The package's installed symbols file, for this host's architecture before the plain name."""
    result = subprocess.run(["dpkg", "--print-architecture"], capture_output=True, check=False, text=True)
    arch = result.stdout.strip()
    names = [f"{owner}:{arch}.symbols"] if re.fullmatch(r"[a-z0-9-]+", arch) else []
    return next((INFO_DIR / name for name in [*names, f"{owner}.symbols"] if (INFO_DIR / name).is_file()), None)


def soname_minimums(owner: str, soname: str, nodes: set[str], table: Table, origin: str) -> set[str]:
    """Each needed node's first package version; version 0 is Debian's mark for no minimum."""
    entry = table.get(soname)
    if entry is None or entry[0] != f"{owner} #MINVER#":
        print(f"deb-depends: {origin} has no plain {owner} template for {soname}; its Depends stays unversioned", file=sys.stderr)
        return set()
    minimums = set()
    for node in sorted(nodes):
        versions = entry[1].get(node)
        if not versions:
            raise ValueError(f"{origin} lists no version node {node} for {soname}")
        minimums.add(oldest(versions))
    return minimums - {"0"}


def package_bound(owner: str, needs: dict[str, set[str]]) -> str:
    """The newest minimum across the sonames this bundle takes from `owner`; empty when no node decides one."""
    wanted = {soname: nodes for soname, nodes in needs.items() if nodes}
    if not wanted:
        return ""
    path = symbols_file(owner)
    if path is None:
        print(f"deb-depends: {owner} installs no symbols file; its Depends stays unversioned", file=sys.stderr)
        return ""
    table = parse_symbols(path.read_text(encoding="utf-8"), str(path))
    minimums: set[str] = set()
    for soname, nodes in sorted(wanted.items()):
        minimums |= soname_minimums(owner, soname, nodes, table, str(path))
    return newest(minimums) if minimums else ""
