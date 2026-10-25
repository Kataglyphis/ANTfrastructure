#!/usr/bin/env python3
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
"""Audits a manifest edit by parsing the file for real, before and after.

See docs/dependency-updates.md#the-edit-is-audited-by-a-real-parser
"""

import collections
import json
import re
import tomllib
from collections.abc import Iterable, Iterator, Sequence
from types import ModuleType
from typing import TYPE_CHECKING, cast

if TYPE_CHECKING:
    from yaml.nodes import MappingNode

import renovate_cmake
import renovate_locator

# start/end: the version's half-open span in leaf; why: "" or the reason a readable declaration may not move.
Decl = collections.namedtuple("Decl", "path leaf start end why", defaults=("",))
DeclPath = tuple[object, ...]
Leaves = dict[DeclPath, tuple[str, object]]

# Every manager renovate_locator.py can edit must be verifiable here; test-renovate-audit.sh asserts it.
FORMATS = {
    "github-actions": "yaml",
    "pub": "yaml",
    "pre-commit": "yaml",
    "pep621": "toml",
    "cargo": "toml",
    "npm": "json",
    "pip_requirements": "requirements",
    "pip-compile": "requirements",
    "regex": "env",
    "custom.regex": "env",
    renovate_locator.CMAKE: "cmake",
}

# YAML aliases can expand a document exponentially; hitting this refuses, never truncates.
MAX_PATHS = 200000

# Bounds the cycle check's cost and hostile nesting; real manifests nest about eight deep.
MAX_DEPTH = 200

# An escape, since the literal is invisible; tomllib rejects a manifest that starts with one.
BOM = "\ufeff"


class Unreadable(Exception):
    """This file's meaning cannot be read, so an edit to it cannot be audited."""


def _yaml() -> ModuleType:
    """PyYAML, or a refusal: a hand-rolled fallback is exactly what this module replaces."""
    try:
        import yaml
    except ImportError as exc:
        raise Unreadable(
            "PyYAML is not installed for this python, and a YAML manifest is "
            "not written unless the edit can be read back by a real YAML "
            "parser -- install it (pip install pyyaml) and re-run"
        ) from exc
    return yaml


def _oneline(text: object) -> str:
    """One line: these messages travel through a tab-separated plan row."""
    return " ".join(str(text).split())


def _duplicate(kind: str, key: object) -> str:
    """The one wording for a repeated key; last-wins parsing would hide the second declaration."""
    return (
        f"this {kind} declares {key!r} twice, so the file says two things about it. "
        "Which one a report means is not knowable, and a manifest that "
        "contradicts itself is not one this tool edits -- nothing is "
        "written"
    )


# Cached, since building it needs the import _yaml() owns.
_LOADER = None


def _loader() -> type:
    """A SafeLoader that refuses a duplicate mapping key instead of resolving it last-wins."""
    global _LOADER
    if _LOADER is not None:
        return _LOADER
    yaml = _yaml()

    class Loader(yaml.SafeLoader):
        def construct_mapping(
            self, node: "MappingNode", deep: bool = False
        ) -> dict[object, object]:
            seen = set()
            for key_node, _value in node.value:
                key = self.construct_object(key_node, deep=True)
                if isinstance(key, (dict, list)):
                    continue  # PyYAML rejects an unhashable key itself
                if key in seen:
                    raise Unreadable(_duplicate("mapping", key))
                seen.add(key)
            return super().construct_mapping(node, deep=deep)

    _LOADER = Loader
    return _LOADER


def _parse_yaml(body: str) -> object:
    yaml = _yaml()
    try:
        return yaml.load(body, Loader=_loader())
    except yaml.YAMLError as exc:
        raise Unreadable(f"PyYAML cannot read it: {_oneline(exc)}") from exc


def _json_pairs(pairs: list[tuple[str, object]]) -> dict[str, object]:
    """One JSON object, refusing a key written twice (json alone takes last-wins)."""
    out = {}
    for key, value in pairs:
        if key in out:
            raise Unreadable(_duplicate("object", key))
        out[key] = value
    return out


def _parse_json(body: str) -> object:
    return json.loads(body, object_pairs_hook=_json_pairs)


def _parse_env(body: str) -> dict[str, dict[str, str]]:
    """An annotated env file as {depName: {KEY: value}}, read independently of the locator's regexes."""
    ann = re.compile(r"^# renovate:.*?\bdepName=(\S+)(?:\s|$)")
    kv = re.compile(r"^([A-Z0-9_]+)=([^\s#]*)$")
    out = {}
    lines = body.split("\n")
    for num, line in enumerate(lines):
        match = ann.match(line)
        if match is None:
            continue
        key_line = num + 1
        while key_line < len(lines) and not lines[key_line].strip():
            key_line += 1
        if key_line < len(lines) and lines[key_line].strip() == "# noforward":
            key_line += 1
        found = kv.match(lines[key_line]) if key_line < len(lines) else None
        if found is None:
            raise Unreadable(
                f"line {num + 1}: the # renovate hint for '{match.group(1)}' is not followed by a "
                "KEY=value line"
            )
        key, value = found.groups()
        values = out.setdefault(match.group(1), {})
        if key in values:
            raise Unreadable(
                f"line {key_line + 1}: {key} is assigned twice, and one leaf cannot carry two "
                "values"
            )
        values[key] = value
    return out


def _joined(lines: Iterable[str]) -> list[str]:
    """requirements.txt lines with pip's backslash continuations joined."""
    out = []
    held = ""
    for line in lines:
        text = renovate_locator.uncomment(line).rstrip("\r")
        if text.rstrip().endswith("\\"):
            held += text.rstrip()[:-1]
            continue
        out.append(held + text)
        held = ""
    if held:
        out.append(held)
    return out


def parse_requirements(text: str) -> list[dict[str, str]]:
    """What a requirements file asks pip for, split into fields so a stray change shows as a second leaf."""
    out = []
    for body in _joined(text.split("\n")):
        text_ = body.strip()
        if not text_:
            continue
        if text_.startswith("-"):
            out.append({"option": text_})
            continue
        parsed = renovate_locator.pep508_span(text_)
        if parsed is None:
            raise Unreadable(
                f"{text_!r} is neither an option line nor a PEP 508 requirement, so "
                "what this file asks for cannot be read"
            )
        name, extras, start, end = parsed
        spec, opts = _spec_and_options(text_[start:end])
        out.append(
            {
                "name": name,
                "extras": extras or "",
                "spec": spec,
                "opts": opts,
                "tail": text_[end:].strip(),
            }
        )
    return out


def _spec_and_options(text: str) -> tuple[str, str]:
    """(specifier, glued-on options such as --hash), so the digests are not compared as the version."""
    cut = text.find(" --")
    if cut < 0:
        return text.strip(), ""
    return text[:cut].strip(), text[cut:].strip()


def hash_pinned(opts: str) -> str:
    """Why a digest-pinned requirement is not moved (nothing here recomputes hashes), or ""."""
    if "--hash" not in opts:
        return ""
    return (
        f"this requirement is pinned by digest ({_oneline(opts)[:80]}), and those digests "
        "describe the release being replaced. Nothing here recomputes them "
        "-- re-run pip-compile -- and pip rejects a requirements file whose "
        "hashes do not match, so the version is not moved on its own"
    )


PARSERS = {
    "yaml": _parse_yaml,
    "toml": tomllib.loads,
    "json": _parse_json,
    "requirements": parse_requirements,
    "env": _parse_env,
    "cmake": renovate_cmake.parse,
}


def parse(manager: str, text: str) -> object:
    """This file's meaning by its real parser; every parser failure, named, becomes Unreadable."""
    kind = FORMATS.get(manager)
    if kind is None:
        raise Unreadable(
            f"there is no real parser here for manager '{manager}', and a file whose "
            "meaning cannot be read back is not written"
        )
    body = text[1:] if text.startswith(BOM) else text
    try:
        return PARSERS[kind](body)
    except Unreadable:
        raise
    except RecursionError as exc:
        raise Unreadable(
            f"it nests too deeply for the {kind} parser to read: {_oneline(exc)}"
        ) from exc
    except Exception as exc:
        raise Unreadable(
            f"it does not read as {kind}: {type(exc).__name__}: {_oneline(exc)}"
        ) from exc


def flatten(struct: object) -> Leaves:
    """Every path with its typed scalar or container shape; iterative, so deep nesting cannot overflow."""
    out = {}
    stack: list[tuple[object, tuple[object, ...], tuple[int, ...]]] = [(struct, (), ())]
    while stack:
        node, path, seen = stack.pop()
        if not isinstance(node, (dict, list)):
            out[path] = (type(node).__name__, node)
            continue
        if id(node) in seen:
            raise Unreadable(
                f"{show(path)} refers back to itself, so this document has no finite set "
                "of paths to compare"
            )
        if len(seen) >= MAX_DEPTH:
            # Elided: in full it is a huge plan row that says nothing more.
            raise Unreadable(
                f"this document nests past {MAX_DEPTH} levels, under {show(path[:4])} ...; it is not "
                "compared rather than compared partially"
            )
        if len(out) > MAX_PATHS:
            raise Unreadable(
                f"this document expands past {MAX_PATHS} paths; it is not compared rather "
                "than compared partially"
            )
        if isinstance(node, dict):
            out[path] = ("{}", tuple(sorted(str(key) for key in node)))
            items = node.items()
        else:
            out[path] = ("[]", len(node))
            items = enumerate(node)
        below = seen + (id(node),)
        for key, value in items:
            stack.append((value, path + (key,), below))
    return out


def show(path: DeclPath) -> str:
    """A path as a human reads it: `jobs.build.steps[0].uses`."""
    out = ""
    for part in path:
        if isinstance(part, int):
            out += f"[{part}]"
        else:
            out += ("." + str(part)) if out else str(part)
    return out or "(the document root)"


def _paths(paths: Iterable[DeclPath]) -> str:
    return ", ".join(sorted(show(path) for path in paths)) or "(none)"


# Declarations, read off the parsed document where the locator has to guess with regexes
def _mapping(node: object) -> dict[object, object]:
    return node if isinstance(node, dict) else {}


def _sequence(node: object) -> list[object]:
    return node if isinstance(node, list) else []


def _whole(path: DeclPath, text: str) -> Decl:
    """A Decl over a whole string leaf, where pub, npm and cargo state only the version."""
    return Decl(path, text, 0, len(text))


def _step_nodes(struct: object) -> Iterator[tuple[DeclPath, dict[object, object]]]:
    """(path, mapping) for each job, job step and composite step: the only places `uses:` declares."""
    root = _mapping(struct)
    for job, node in _mapping(root.get("jobs")).items():
        if not isinstance(node, dict):
            continue
        yield ("jobs", job), node
        for i, step in enumerate(_sequence(node.get("steps"))):
            if isinstance(step, dict):
                yield ("jobs", job, "steps", i), step
    for i, step in enumerate(_sequence(_mapping(root.get("runs")).get("steps"))):
        if isinstance(step, dict):
            yield ("runs", "steps", i), step


def _uses(path: DeclPath, node: dict[object, object], want: str) -> Decl | None:
    """The Decl for one `uses:` naming this action, split at the last `@`."""
    text = node.get("uses")
    if not isinstance(text, str):
        return None
    repo, at, _ref = text.rpartition("@")
    if not at:
        return None
    folded = repo.casefold()
    if folded != want and not folded.startswith(want + "/"):
        return None
    return Decl(path + ("uses",), text, len(repo) + 1, len(text))


def decl_actions(struct: object, dep: str) -> list[Decl]:
    want = dep.casefold()
    found = (_uses(path, node, want) for path, node in _step_nodes(struct))
    return [decl for decl in found if decl is not None]


def decl_pub(struct: object, dep: str) -> list[Decl]:
    """The dep's scalar in a top-level pubspec section; a map-shaped dep states no version here."""
    root = _mapping(struct)
    out = []
    for section in renovate_locator.PUB_SECTIONS:
        version = _mapping(root.get(section)).get(dep)
        if isinstance(version, str):
            out.append(_whole((section, dep), version))
    return out


def decl_precommit(struct: object, dep: str) -> list[Decl]:
    out = []
    want = dep.casefold()
    for i, item in enumerate(_sequence(_mapping(struct).get("repos"))):
        if not isinstance(item, dict) or not isinstance(item.get("rev"), str):
            continue
        if renovate_locator.repo_name(str(item.get("repo", ""))) == want:
            out.append(_whole(("repos", i, "rev"), item["rev"]))
    return out


def _dig(struct: object, path: DeclPath) -> object:
    node = struct
    for part in path:
        node = _mapping(node).get(part)
    return node


def _array(out: list[Decl], array: object, path: DeclPath, want: str) -> None:
    """Every PEP 508 string in one dependency array that names `want`."""
    for i, text in enumerate(_sequence(array)):
        if not isinstance(text, str):
            continue
        parsed = renovate_locator.pep508_span(text)
        if parsed is None or renovate_locator.normalise(parsed[0]) != want:
            continue
        out.append(Decl(path + (i,), text, parsed[2], parsed[3]))


def decl_pep621(struct: object, dep: str) -> list[Decl]:
    """Specifiers of PEP 508 strings naming the dep, in the locator's tables as tomllib places them."""
    out = []
    want = renovate_locator.normalise(dep)
    for table, keys in renovate_locator.PEP621_KEYS.items():
        for key in keys:
            _array(out, _mapping(_dig(struct, table)).get(key), table + (key,), want)
    for table in renovate_locator.PEP621_TABLES:
        for key, array in _mapping(_dig(struct, table)).items():
            _array(out, array, table + (key,), want)
    return out


def _cargo_roots(struct: object) -> Iterator[tuple[DeclPath, dict[object, object]]]:
    """Mappings whose `[dependencies]` are cargo's: root, `[workspace]`, each `[target.<cfg>]`."""
    root = _mapping(struct)
    yield (), root
    workspace = root.get("workspace")
    if isinstance(workspace, dict):
        yield ("workspace",), workspace
    for cfg, node in _mapping(root.get("target")).items():
        if isinstance(node, dict):
            yield ("target", cfg), node


def decl_cargo(struct: object, dep: str) -> list[Decl]:
    """The crate's version, bare or under `version`; `{ workspace = true }` states none here."""
    out = []
    for base, node in _cargo_roots(struct):
        for table in renovate_locator.CARGO_TABLES:
            spec = _mapping(node.get(table)).get(dep)
            if isinstance(spec, str):
                out.append(_whole(base + (table, dep), spec))
            elif isinstance(version := _mapping(spec).get("version"), str):
                out.append(_whole(base + (table, dep, "version"), version))
    return out


def decl_npm(struct: object, dep: str) -> list[Decl]:
    root = _mapping(struct)
    out = []
    for obj in renovate_locator.NPM_OBJECTS:
        version = _mapping(root.get(obj)).get(dep)
        if isinstance(version, str):
            out.append(_whole((obj, dep), version))
    return out


def decl_annotated(struct: object, dep: str) -> list[Decl]:
    """Every KEY= value the hints name for this dep; KEY is the path, as deps can share a name."""
    return [
        _whole((dep, key), cast(str, value))
        for key, value in sorted(_mapping(_mapping(struct).get(dep)).items())
    ]


def decl_requirements(struct: object, dep: str) -> list[Decl]:
    """Every requirement naming this dep; glued-on digests forbid moving it."""
    want = renovate_locator.normalise(dep)
    out = []
    for i, entry in enumerate(_sequence(struct)):
        if not isinstance(entry, dict):
            continue
        if entry.get("name") is None:
            continue
        if renovate_locator.normalise(entry["name"]) != want:
            continue
        spec = entry["spec"]
        out.append(Decl((i, "spec"), spec, 0, len(spec), hash_pinned(entry["opts"])))
    return out


def decl_cmake(struct: object, dep: str) -> list[Decl]:
    """Every declaration of dep the preset's CMake forms read, found in CMake's token stream."""
    cmake_tokens = cast(dict[str, renovate_cmake.CmakeToken], struct)
    return [Decl(*found) for found in renovate_cmake.declarations(cmake_tokens, dep)]


DECLARERS = {
    "github-actions": decl_actions,
    "pub": decl_pub,
    "pre-commit": decl_precommit,
    "pep621": decl_pep621,
    "cargo": decl_cargo,
    "npm": decl_npm,
    "pip_requirements": decl_requirements,
    "pip-compile": decl_requirements,
    "regex": decl_annotated,
    "custom.regex": decl_annotated,
    renovate_locator.CMAKE: decl_cmake,
}


# The invariant, computed before the edit and checked after it
def _miscount(
    dep: str, old: str, count: int, found: list[Decl], at_old: list[Decl]
) -> str:
    """Why the parse and the report disagree: declared nowhere, elsewhere, or more often."""
    where = ", ".join(f"{show(d.path)}={d.leaf[d.start : d.end]}" for d in found)
    if not found:
        return (
            f"a real parser finds no declaration of '{dep}' in this file at "
            "all, so whatever line was picked to rewrite is not one; "
            "nothing is written"
        )
    if not at_old:
        return (
            f"a real parser reads this file as declaring '{dep}' at {where}, and "
            f"none of those carries the reported current value {old} -- "
            "something moved, so nothing is written"
        )
    return (
        f"a real parser reads this file as declaring '{dep}' at {where} -- {len(at_old)} of "
        f"them at the reported {old}, against {count} update(s) in the report. "
        "Which declaration the report means is not knowable from the "
        "file, so nothing is written"
    )


def _crashed(doing: str, exc: Exception) -> str:
    """A refusal naming an unexpected exception, which must not escape past the rollback."""
    return (
        f"{doing} raised {type(exc).__name__}: {_oneline(exc)}. That is a defect in the auditor rather than a "
        "verdict on the file, and an audit that cannot finish does not "
        "sanction an edit -- so nothing is kept"
    )


def _expected(
    manager: str, text: str, groups: Sequence[tuple[str, str, str, int]]
) -> tuple[dict[DeclPath, str], Leaves, str]:
    struct = parse(manager, text)
    leaves = flatten(struct)
    want = {}
    for dep, old, new, count in groups:
        found = DECLARERS[manager](struct, dep)
        at_old = [d for d in found if d.leaf[d.start : d.end] == old]
        if len(at_old) != count:
            return {}, {}, _miscount(dep, old, count, found, at_old)
        for decl in at_old:
            # Readable but not movable: its own reason, not a miscount.
            if decl.why:
                return {}, {}, f"{show(decl.path)} declares '{dep}', and {decl.why}"
            if decl.path in want:
                return (
                    {},
                    {},
                    (
                        f"two of this report's updates both claim {show(decl.path)}; one value "
                        "cannot become two things"
                    ),
                )
            rewritten = decl.leaf[: decl.start] + new + decl.leaf[decl.end :]
            # old == new is a lockfile-only update; `want` holds only paths that must move.
            if rewritten != decl.leaf:
                want[decl.path] = rewritten
    return want, leaves, ""


def expected(
    manager: str, text: str, groups: Sequence[tuple[str, str, str, int]]
) -> tuple[dict[DeclPath, str], Leaves, str]:
    """(path -> leaf it must carry, this document's leaves, refusal), from the parse alone; never raises.

    groups: one (dep, old, new, count) per reported pin.
    """
    try:
        return _expected(manager, text, groups)
    except Unreadable as exc:
        return {}, {}, str(exc)
    except Exception as exc:  # noqa: BLE001 -- see _crashed
        return {}, {}, _crashed("working out what the edit may change", exc)


def _shape(gone: set[DeclPath], born: set[DeclPath]) -> str:
    """A bump adds and removes no path; one that does escaped its quoting or changed the format's reading."""
    parts = []
    if gone:
        parts.append(f"{len(gone)} path(s) disappeared ({_paths(gone)})")
    if born:
        parts.append(f"{len(born)} appeared ({_paths(born)})")
    return (
        "the edit changed the SHAPE of the file: "
        + " and ".join(parts)
        + ". A version bump adds and removes nothing"
    )


def _elsewhere(moved: set[DeclPath], want: dict[DeclPath, str]) -> str:
    stray = moved - set(want)
    missed = set(want) - moved
    parts = []
    if stray:
        parts.append(
            f"it changed {_paths(stray)}, which declares nothing this report names"
        )
    if missed:
        parts.append(
            f"it left {_paths(missed)}, the declaration the report named, alone"
        )
    return (
        "the edit did not land where the report's dependency is declared: "
        + "; and ".join(parts)
    )


def audit(
    manager: str,
    before_text: str,
    after_text: str,
    groups: Sequence[tuple[str, str, str, int]],
) -> str:
    """Return a refusal reason unless exactly the reported declarations moved."""
    try:
        return _audit(manager, before_text, after_text, groups)
    except Exception as exc:  # noqa: BLE001 -- see _crashed
        return _crashed("auditing the file after the write", exc)


def _audit(
    manager: str,
    before_text: str,
    after_text: str,
    groups: Sequence[tuple[str, str, str, int]],
) -> str:
    want, before_leaves, why = expected(manager, before_text, groups)
    if why:
        return why
    try:
        after_leaves = flatten(parse(manager, after_text))
    except Unreadable as exc:
        return f"after the edit, {exc}"
    gone = set(before_leaves) - set(after_leaves)
    born = set(after_leaves) - set(before_leaves)
    if gone or born:
        return _shape(gone, born)
    moved = {p for p in before_leaves if before_leaves[p] != after_leaves[p]}
    if moved != set(want):
        return _elsewhere(moved, want)
    for path in sorted(moved, key=show):
        if after_leaves[path] != ("str", want[path]):
            return (
                f"{show(path)} now reads {after_leaves[path][1]!r}, and the reported update makes it "
                f"{want[path]!r}"
            )
    return ""
