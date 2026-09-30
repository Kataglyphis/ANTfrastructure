#!/usr/bin/env python3
"""Detection-only check of versions.env pins a consumer repeats in its own metadata; the hub root is a parameter, never derived from __file__."""

from __future__ import annotations

import re
import sys
from pathlib import Path

# key, file, mention regex, version regex, label; mention vs version tells unused from unpinned; PEP 621 shape only (a poetry table is skipped).
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
    # The image build forces these over the app lock, so a lagging pin splits dev box and image.
    (
        "PYTORCH_VERSION",
        "pyproject.toml",
        r'"torch(?=[=<>~!\[",;])',
        r'"torch==([^"\s;,]+)',
        'the `"torch==<version>"` pin',
    ),
    (
        "PYTORCH_VERSION",
        "pyproject.toml",
        r"github\.com/pytorch/pytorch(?:\.git)?@",
        r"github\.com/pytorch/pytorch(?:\.git)?@v?([^\s\"';]+)",
        "the riscv64 `pytorch.git@<tag>` source pin",
    ),
    (
        "TORCHVISION_VERSION",
        "pyproject.toml",
        r'"torchvision(?=[=<>~!\[",;])',
        r'"torchvision==([^"\s;,]+)',
        'the `"torchvision==<version>"` pin',
    ),
    (
        "TORCHVISION_VERSION",
        "pyproject.toml",
        r"github\.com/pytorch/vision(?:\.git)?@",
        r"github\.com/pytorch/vision(?:\.git)?@v?([^\s\"';]+)",
        "the riscv64 `vision.git@<tag>` source pin",
    ),
    # -cuda is the same release renamed; -directml is unpinned on purpose, so not a mention.
    (
        "ONNXRUNTIME_GENAI_VERSION",
        "pyproject.toml",
        r'"onnxruntime-genai(?:-cuda)?(?=[=<>~!\[",;])',
        r'"onnxruntime-genai(?:-cuda)?==([^"\s;,]+)',
        'the `"onnxruntime-genai[-cuda]==<version>"` pin',
    ),
)


def _bare(version: str) -> str:
    """Drop a tag's leading v, since versions.env spells some keys as the GitHub tag."""
    return re.sub(r"^v(?=\d)", "", version)


def _strip_hash_comments(text: str) -> str:
    """Blank `#` comments out of TOML/YAML, keeping the line count the .pre-commit rev window counts."""
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
    """Every distinct version the extractor reads, in file order, so a stale duplicate is caught."""
    seen: list[str] = []
    for match in re.finditer(value_rx, text):
        if match.group(1) not in seen:
            seen.append(match.group(1))
    return seen


def consumer_pin_roots(
    named: list[str], repo_root: Path
) -> tuple[list[Path], list[str], int]:
    """(roots, how each was named, rc) for the consumer checkouts; a named root that does not exist is an error."""
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
    # Only the vendored shape counts: a checkout at <consumer>/third_party/<name> is inside that consumer.
    if repo_root.parent.name == "third_party":
        vendored = repo_root.parents[1]
        if vendored not in roots:
            roots.append(vendored)
            how.append(f"{vendored} (vendored at third_party/{repo_root.name})")
    return roots, how, rc


def _grade_pin(
    path: Path, text: str, value_rx: str, what: str, key: str, expected: str
) -> int:
    """Grade one declared pin: 0 when it matches versions.env, 1 when not."""
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
    if found != _bare(expected):
        print(
            f"{path}: {what} is {found}, versions.env has {key}={expected}. "
            f"versions.env is the source of truth: change the consumer, "
            f"not this file.",
            file=sys.stderr,
        )
        return 1
    return 0


def _check_root(versions: dict[str, str], root: Path) -> tuple[int, int, list[str]]:
    """(bad, compared, files looked for) for one checkout, counted per root so its verdict line cannot read green over a drift."""
    compared = 0
    bad = 0
    looked_for: list[str] = []
    for key, rel, mention_rx, value_rx, what in CONSUMER_PIN_ROWS:
        if rel not in looked_for:
            looked_for.append(rel)
        expected = versions.get(key)
        if not expected:
            # A row that outlived its key fails loud instead of skipping silently.
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
        # Say that zero pins were compared, so "none declared" never reads as a pass.
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
