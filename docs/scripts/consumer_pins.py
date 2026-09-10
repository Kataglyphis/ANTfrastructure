#!/usr/bin/env python3
"""consumer_pins.py — the one versions.env consumer this repo does not own.

sync_versions.py propagates `linux/scripts/01-core/versions.env` into every file
that repeats one of its numbers. Seven of its eight targets are files in THIS
repository, so it both checks and rewrites them. This module is the eighth, and
it is a different job under a different contract: the pin lives in a CONSUMER
repository's own package metadata, which this repo may read and must never
write.

Some pins have no choice but to be repeated there. pip/uv read `pyproject.toml`
and pre-commit reads `.pre-commit-config.yaml`, and neither tool can read a
`versions.env`. RUFF_VERSION is the live case — declared three times, here and
twice in OrchestrANT (`"ruff==..."` in pyproject.toml, `rev:` in
.pre-commit-config.yaml), hand-synced across two repositories. It has already
drifted once: the consumer sat on 0.15.21 while this repo graded the Linux lane
with 0.16.4, so the same tree passed locally and failed in CI on rules that moved
between the two versions. Nothing in the fleet could see that, because every gate
that knew the number only looked at its own tree.

DETECTION ONLY, deliberately. This repo does not own a consumer's files, so there
is no `--write` pass here and NEITHER mode writes outside the hub; the report
names the file, both values, and the edit to make. It runs in `--write` too,
because `--write`'s whole claim is "versions.env is now propagated everywhere"
and this is the one place it cannot propagate to — a bump that leaves a consumer
contradicting the new value must not exit 0.

The consumer root is NAMED, never searched for — the same contract
run-lint-gates.sh and 01-core/lint-root.sh spell out for the lint gates, for the
same reason: a root nobody named is a verdict about a tree nobody looked at.
Three ways to name one:
  --consumer-root <dir>   explicit, repeatable;
  the vendored position   when the hub checkout IS <consumer>/third_party/<x>,
                          <consumer> is a fact about the hub's own path, not a
                          guess about somebody else's layout.
  --consumer-pins         the mode run-lint-gates.sh uses: check ONLY this
                          section, over the root the consumer already had to
                          name to run any gate at all.

WHERE IT ACTUALLY RUNS, because a check nobody calls proves nothing. Until
2026-09-09 the only caller was preflight.sh's `--check`, which runs in a
STANDALONE hub clone: no `--consumer-root`, not vendored, so it printed
"NOT CHECKED" and exited 0 on every run in the hub's own lane, and no consumer
invoked the script at all. The lane that HAS a consumer root is the consumer's
own: run-lint-gates.sh takes it as a mandatory first argument, and OrchestrANT's
lint-gates.yml runs it on every push and PR. So the `consumer pins` gate lives
there, and `--consumer-pins` is the entry point it calls. In the hub's own lane
the section still says NOT CHECKED — correctly, there is no consumer there.

In `--consumer-pins` mode a missing root is FATAL rather than a printed
"NOT CHECKED": the mode was asked for by name, so zero roots means the caller is
broken, not that there was nothing to look at.

The hub root is a PARAMETER here, never derived from this file's `__file__`.
That is the scan-root contract the ratchet gates already live under
(docs/code-quality-tooling.md#the-scan-root-contract), and it is load-bearing for
the test suite: test-version-snapshot.sh runs against a symlink farm and
materialises only sync_versions.py as a real copy, so a `Path(__file__).resolve()`
in THIS file would follow the symlink back to the real tree and grade a different
root than its own caller.
docs/code-quality-tooling.md#the-mutation-gate-mutations
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

# key, consumer-relative file, "is this pin declared here at all" regex,
# "read the version" regex (one group), and what to call it in a message.
# The mention/extract split is what separates "this consumer does not use ruff"
# (skip, correct) from "this consumer uses ruff but the version is unreadable"
# (fail — an UNPINNED `"ruff"` is exactly how the 0.15.21 drift happened, and a
# single regex that just fails to match cannot tell the two apart).
# Both regexes run over COMMENT-STRIPPED text (_strip_hash_comments below) and
# every match has to agree, because "first match anywhere in the file wins" was
# readable-but-wrong: OrchestrANT's pyproject.toml names `"ruff"` in a comment
# four lines above the real dependency, and a commented-out historical pin in
# that position would have been read AS the pin. Same for the `rev:`.
# KNOWN SHAPE LIMIT, stated rather than papered over: the pyproject row reads the
# PEP 621 list shape (`"ruff==<v>"`), which is what the consumers here use. A
# poetry-style `ruff = "^0.16"` table entry matches neither regex and is skipped
# silently — add a row for that shape the day a consumer grows one. The
# .pre-commit row's 20-line window is the other bound: a `rev:` further from its
# `repo:` than that FAILS loudly ("no readable version") rather than passing.
# The window is `[ \t]*`, never `\s*`: `\s` eats newlines, so the bound the
# comment claims would have been unenforceable in the one direction that matters.
CONSUMER_PIN_ROWS: tuple[tuple[str, str, str, str, str], ...] = (
    (
        "RUFF_VERSION",
        "pyproject.toml",
        r'"ruff(?=[=<>~!\[",])',
        r'"ruff==([^"\s]+)"',
        'the `"ruff==<version>"` dependency pin',
    ),
    (
        "RUFF_VERSION",
        ".pre-commit-config.yaml",
        r"astral-sh/ruff-pre-commit",
        (
            r"astral-sh/ruff-pre-commit[^\n]*\n(?:[^\n]*\n){0,20}?[ \t]*rev:[ \t]*"
            r"[\"']?v?([^\s\"'#]+)"
        ),
        "the ruff-pre-commit `rev:`",
    ),
)


def _strip_hash_comments(text: str) -> str:
    """Blank the `#` comments out of TOML/YAML text, keeping the line count.

    Both consumer files comment with `#` and quote with `"`/`'`, so one walker
    serves both rows. The line COUNT is preserved because the .pre-commit
    extractor counts lines between its `repo:` and its `rev:`; dropping comment
    lines outright would silently widen that window.
    """
    out = []
    for line in text.split("\n"):
        quote = ""
        cut = None
        for index, char in enumerate(line):
            if quote:
                if char == quote:
                    quote = ""
            elif char in "\"'":
                quote = char
            elif char == "#":
                cut = index
                break
        out.append(line if cut is None else line[:cut])
    return "\n".join(out)


def consumer_pin_values(text: str, value_rx: str) -> list[str]:
    """Every DISTINCT version the extractor reads, in file order.

    A list rather than the first match: one file declaring a pin twice with two
    values is a real shape (a stale block left above the live one), and reading
    only the first is how that goes unnoticed.
    """
    seen: list[str] = []
    for match in re.finditer(value_rx, text):
        if match.group(1) not in seen:
            seen.append(match.group(1))
    return seen


def consumer_pin_roots(
    named: list[str], repo_root: Path
) -> tuple[list[Path], list[str], int]:
    """Resolve the consumer checkouts to compare against. Returns
    (roots, how-each-was-named, rc). A named root that does not exist is an
    ERROR and not a skip: silently checking nothing is the failure mode this
    whole module exists to prevent."""
    roots: list[Path] = []
    how: list[str] = []
    rc = 0
    for raw in named:
        path = Path(raw).expanduser()
        if not path.is_dir():
            print(f"--consumer-root {raw}: not a directory", file=sys.stderr)
            rc = 1
            continue
        resolved = path.resolve()
        if resolved not in roots:
            roots.append(resolved)
            how.append(f"{resolved} (--consumer-root)")
    # The vendored position. Only this exact shape counts: a checkout sitting at
    # <consumer>/third_party/<name> IS inside that consumer, which is knowledge
    # about our own path rather than a search of the disk.
    if repo_root.parent.name == "third_party":
        vendored = repo_root.parents[1]
        if vendored not in roots:
            roots.append(vendored)
            how.append(f"{vendored} (vendored at third_party/{repo_root.name})")
    return roots, how, rc


def _grade_pin(
    path: Path, text: str, value_rx: str, what: str, key: str, expected: str
) -> int:
    """Grade ONE pin the consumer really declares: 0 when it matches, 1 when it
    does not. Only reached once the file exists and the mention regex hit, so
    every return here is a pin the caller counts as COMPARED either way."""
    values = consumer_pin_values(text, value_rx)
    if not values:
        print(
            f"{path}: {what} is present but carries no readable version, "
            f"so nothing holds it to versions.env {key}={expected}. "
            f"Pin it explicitly.",
            file=sys.stderr,
        )
        return 1
    if len(values) > 1:
        print(
            f"{path}: {what} is declared more than once, with disagreeing "
            f"values ({', '.join(values)}). Which one a tool reads is a "
            f"detail of its parser, so this cannot be graded against "
            f"versions.env {key}={expected} — leave one.",
            file=sys.stderr,
        )
        return 1
    found = values[0]
    if found != expected:
        print(
            f"{path}: {what} is {found}, versions.env has {key}={expected}. "
            f"versions.env is the source of truth: change the consumer, "
            f"not this file.",
            file=sys.stderr,
        )
        return 1
    return 0


def _check_root(versions: dict[str, str], root: Path) -> tuple[int, int, list[str]]:
    """Grade every CONSUMER_PIN_ROWS row against ONE checkout. Returns
    (bad, compared, files-looked-for).

    Counted per-root, because the summary line must never read green over a root
    that just printed a drift. An accumulator that only lived in the caller's rc
    did exactly that in the first cut of this check."""
    compared = 0
    bad = 0
    looked_for: list[str] = []
    for key, rel, mention_rx, value_rx, what in CONSUMER_PIN_ROWS:
        if rel not in looked_for:
            looked_for.append(rel)
        expected = versions.get(key)
        if not expected:
            # The row outlived its key. Loud, like deps_table's KeyError:
            # a renamed key must not degrade this row into a silent skip.
            print(
                f"CONSUMER_PIN_ROWS names {key}, which versions.env does not "
                f"define — the {rel} pin cannot be checked.",
                file=sys.stderr,
            )
            compared += 1
            bad += 1
            continue
        path = root / rel
        if not path.is_file():
            continue
        text = _strip_hash_comments(path.read_text(encoding="utf-8"))
        if not re.search(mention_rx, text):
            continue
        compared += 1
        bad += _grade_pin(path, text, value_rx, what, key, expected)
    return bad, compared, looked_for


def _report_root(label: str, bad: int, compared: int, looked_for: list[str]) -> None:
    """The one verdict line for one consumer checkout."""
    if bad:
        print(
            f"Consumer pins DISAGREE with versions.env: {label} "
            f"({bad} of {compared} checked pin(s) wrong)."
        )
    elif compared:
        print(f"Consumer pins match versions.env: {label} ({compared} compared).")
    else:
        # Never a bare green line: say that zero pins were compared, so a
        # consumer that simply has none of these files cannot be mistaken
        # for one that was checked and passed.
        print(
            f"Consumer pin forwarding: {label} declares none of "
            f"{', '.join(looked_for)} — 0 pins compared."
        )


def check_consumer_pins(
    versions: dict[str, str],
    named: list[str],
    repo_root: Path,
    required: bool = False,
) -> int:
    roots, how, rc = consumer_pin_roots(named, repo_root)
    if not roots:
        if required:
            # --consumer-pins named this check; zero roots is a broken caller.
            print(
                "--consumer-pins: no usable consumer checkout to compare against "
                "(pass --consumer-root <dir>, or run this from a third_party/ "
                "checkout inside one). Refusing to report a verdict over nothing.",
                file=sys.stderr,
            )
            return 1
        print(
            "Consumer pin forwarding: NOT CHECKED — no usable consumer checkout "
            "(pass --consumer-root <dir>, or run this from a third_party/ "
            "checkout inside one). In the fleet this runs in the CONSUMER's "
            "lane, as run-lint-gates.sh's `consumer pins` gate."
        )
        return rc

    for root, label in zip(roots, how):
        bad, compared, looked_for = _check_root(versions, root)
        if bad:
            rc = 1
        _report_root(label, bad, compared, looked_for)
    return rc
