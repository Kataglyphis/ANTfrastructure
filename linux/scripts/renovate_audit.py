#!/usr/bin/env python3
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
"""What the manifest MEANS, read by a real parser, before and after the edit.

renovate_locator.py answers "which line declares this dependency" by parsing
each manager's syntax by hand. Five rounds of adversarial fixtures each closed
the cases found and had the next round find new ones -- a YAML anchor on the
`dependencies:` key, a UTF-8 BOM before the first TOML table header, the block
scalar header spelled `|2-` rather than `|-2`. Every one of them is legal
syntax, every one made --apply write the WRONG declaration, and none of them was
the last. A hand-rolled parser for YAML, TOML and JSON cannot be emptied of edge
cases by iteration, so this module does not try. It changes the KIND of
guarantee instead.

The locator proposes; this module DISPOSES, and it does not trust the locator to
have been right. Before a file is written its meaning is read with PyYAML,
tomllib or json -- the real thing, the same parsers the ecosystem itself uses --
and the paths that DECLARE the reported dependency at the reported old value are
worked out from that parse alone, never from the line the locator picked. After
the file is written it is read from disk and parsed AGAIN, and the two meanings
are diffed. One leaf per reported update may differ, each at one of those paths,
each carrying exactly the value the report asked for. Two values changed, a
different path, a key added or removed, a file that no longer parses: every one
of those is a refusal, and after a write a refusal puts the file back.

Five consequences, each a decision rather than an accident:

  * A manifest that does not parse BEFORE the edit cannot be verified this way,
    and this module refuses to touch it. Writing into a file whose meaning
    cannot be read is precisely the thing the five rounds kept doing.
  * PyYAML loses comments and formatting, so the comparison cannot be textual.
    It is not meant to be. What is compared is the PARSED structure, which is
    exactly the invariant that matters: the meaning changed in one place.
  * An anchor or alias makes one YAML node reachable at several paths, and a
    text edit cannot change one of them without changing the others. Paths are
    therefore counted, not nodes: an aliased declaration reads as more than one
    changed leaf, and the run refuses rather than pretend the blast radius was
    one. See docs/dependency-updates.md#the-edit-is-audited-by-a-real-parser.
  * A DUPLICATE key is refused, in every format that permits one to be written.
    YAML and JSON both resolve `http: 1.1.0` twice in one mapping to last-wins,
    and so does the locator -- so the two AGREE, the edit lands on the winner,
    and the file is left saying two different things about one dependency at
    rc 0. Measured 2026-09-10. PyYAML is therefore driven through a loader that
    RAISES on a repeated key and json through an object hook that does the same;
    tomllib already refuses one. A manifest that contradicts itself is not one
    this tool edits.
  * NOTHING here may raise past its caller. The audit is what triggers the
    rollback, so an audit that dies takes the rollback with it: a hostile
    newValue carrying 1200 nested arrays made the walk below hit the recursion
    limit, the exception went past _put_back(), and the bad write stayed on
    disk at rc 1 (measured 2026-09-10 against renovate_planner.py edit). So the
    walk is ITERATIVE and depth-limited, and expected() and audit() turn any
    exception at all into a refusal that names it. renovate_planner.py rolls
    back on an exception as well, because a guarantee that rests on this
    module's own correctness is the guarantee this module exists to replace.

The entry points are expected() -- what the edit is allowed to do, computed
before it happens -- and audit(), which says whether it did that and nothing
else. renovate_planner.py is the only caller.
"""
import collections
import json
import tomllib

import renovate_locator

# path: the tuple of keys and indices leading to a leaf, as flatten() spells it.
# leaf: the parsed string that leaf holds. start/end: the half-open span of the
# VERSION inside it, so `actions/checkout@v4` yields (17, 19) and the expected
# new leaf is leaf[:start] + new + leaf[end:] -- the same arithmetic the locator
# does on a raw line, done here on the parsed value instead.
# why: empty when this declaration may be rewritten, and otherwise the reason it
# may not. A declaration can be perfectly readable and still not be one this
# tool may move -- a requirement pinned by digest is the measured case -- and
# that is a different verdict from "this file cannot be read".
Decl = collections.namedtuple("Decl", "path leaf start end why",
                              defaults=("",))

# Which real parser reads a manager's files. Every manager renovate_locator.py
# can locate in must appear here: a manager that can be edited but not verified
# would be a hole exactly where this module exists to close one, and
# test-renovate-local.sh asserts the two key sets are equal.
FORMATS = {
    "github-actions": "yaml",
    "pub": "yaml",
    "pre-commit": "yaml",
    "pep621": "toml",
    "cargo": "toml",
    "npm": "json",
    "pip_requirements": "requirements",
    "pip-compile": "requirements",
}

# A ceiling on how many paths one manifest may have. A YAML document can expand
# to far more nodes than it has bytes -- `&a [x,x] &b [*a,*a] &c [*b,*b] ...`
# doubles per line -- and the report that names the file is JSON someone else
# wrote. Hitting this is a refusal, never a truncated comparison.
MAX_PATHS = 200000

# And a ceiling on how DEEP it may nest. Two jobs, one number: it keeps the walk
# below cheap (the cycle check is against the ancestors of the node in hand, so
# its cost is the depth) and it is the second half of the recursion fix -- the
# hostile newValue that beat the recursive walk nested 1200 deep, which json
# itself parses without complaint. No manifest in this family nests past about
# eight; 200 is far above every real one and far below anything that costs.
MAX_DEPTH = 200

# U+FEFF, written as an escape because as a literal it is an invisible byte in
# the middle of a comparison. It is what a Windows editor puts in front of a
# manifest, and what made tomllib reject a pyproject.toml the locator then
# mis-parsed into writing the [dependency-groups] entry instead of [project]'s.
BOM = "\ufeff"


class Unreadable(Exception):
    """This file's meaning cannot be read, so an edit to it cannot be audited."""


def _yaml():
    """PyYAML, or a refusal naming it.

    A YAML manifest cannot be verified without a real YAML parser, and the whole
    point of this module is that a hand-rolled substitute is not one. So a
    missing PyYAML ends the run saying so, rather than quietly falling back to
    the guarantee this module was written to replace."""
    try:
        import yaml
    except ImportError as exc:
        raise Unreadable(
            "PyYAML is not installed for this python, and a YAML manifest is "
            "not written unless the edit can be read back by a real YAML "
            "parser -- install it (pip install pyyaml) and re-run") from exc
    return yaml


def _oneline(text):
    """One line: these messages travel through a tab-separated plan row."""
    return " ".join(str(text).split())


def _duplicate(kind, key):
    """The one wording every format uses for a repeated key.

    YAML and JSON both take the LAST of two equal keys, and so does the locator
    reading the same file line by line -- so the two agree, the edit lands on
    the winner, and the file is left declaring the dependency twice at two
    different values with the run reporting success. The asymmetry is what
    proved it an oversight rather than a policy: a plan aimed at the SHADOWED
    copy IS caught, because the winner never moves. So neither is written."""
    return ("this %s declares %r twice, so the file says two things about it. "
            "Which one a report means is not knowable, and a manifest that "
            "contradicts itself is not one this tool edits -- nothing is "
            "written" % (kind, key))


# PyYAML's own loader, subclassed once and cached, because building it needs the
# import that _yaml() is the single owner of.
_LOADER = None


def _loader():
    """A SafeLoader that REFUSES a duplicate mapping key.

    PyYAML resolves one silently to last-wins. Counting keys after the fact
    would mean walking the node tree a second time in this module; making the
    parser itself say no keeps the answer where the parse is."""
    global _LOADER
    if _LOADER is not None:
        return _LOADER
    yaml = _yaml()

    class Loader(yaml.SafeLoader):
        def construct_mapping(self, node, deep=False):
            seen = set()
            for key_node, _value in node.value:
                key = self.construct_object(key_node, deep=True)
                if isinstance(key, (dict, list)):
                    continue          # PyYAML rejects an unhashable key itself
                if key in seen:
                    raise Unreadable(_duplicate("mapping", key))
                seen.add(key)
            return super().construct_mapping(node, deep=deep)

    _LOADER = Loader
    return _LOADER


def _parse_yaml(body):
    yaml = _yaml()
    try:
        return yaml.load(body, Loader=_loader())
    except yaml.YAMLError as exc:
        raise Unreadable("PyYAML cannot read it: %s" % _oneline(exc)) from exc


def _json_pairs(pairs):
    """One JSON object, or a refusal naming the key written twice. json takes
    last-wins as silently as PyYAML does."""
    out = {}
    for key, value in pairs:
        if key in out:
            raise Unreadable(_duplicate("object", key))
        out[key] = value
    return out


def _parse_json(body):
    return json.loads(body, object_pairs_hook=_json_pairs)


def _joined(lines):
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


def parse_requirements(text):
    """What a requirements file ASKS PIP FOR, as an ordered list of records.

    requirements.txt has no standard parser, so this is one -- small, and
    deliberately not line-shaped. Comments and blank lines carry no meaning and
    are dropped; continuations are joined, because pip joins them; each
    requirement is split into the name as written, its extras, its version
    specifier, the options glued after it and the marker. Splitting is what
    makes the diff useful: rewriting the version moves the `spec` field and
    nothing else, so a write that also disturbed the name, the marker or a
    `--hash` shows up as a second changed leaf and the run refuses.

    Option lines (-r, -e, --hash on its own) are kept in order and whole. They
    are meaning too -- an `-r` that moved would change what the file requests --
    and none of them is ever a rewrite target."""
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
                "%r is neither an option line nor a PEP 508 requirement, so "
                "what this file asks for cannot be read" % text_)
        name, extras, start, end = parsed
        spec, opts = _spec_and_options(text_[start:end])
        out.append({"name": name, "extras": extras or "", "spec": spec,
                    "opts": opts, "tail": text_[end:].strip()})
    return out


def _spec_and_options(text):
    """A version specifier and the per-requirement options glued after it.

    `pip-compile --generate-hashes` writes `ruff==0.9.0 \\` and then a line of
    `--hash=sha256:...`, which pip joins back onto the requirement. Left in the
    specifier, those digests would be part of the value being compared, so a
    file whose hashes are pinned could never be verified -- and they are not the
    version, they are a second thing about the same requirement. Splitting them
    out is what lets hash_pinned() below see them and refuse for the RIGHT
    reason; before renovate_locator.py learned to join pip's continuations, such
    a file was refused one step earlier and for the wrong one."""
    cut = text.find(" --")
    if cut < 0:
        return text.strip(), ""
    return text[:cut].strip(), text[cut:].strip()


def hash_pinned(opts):
    """Why a requirement pinned by digest is not one this tool moves, or "".

    The digests describe the artefacts of the release being replaced. Nothing
    here can recompute them -- that is `pip-compile`'s job, and this tool knows
    no lock command for a requirements file -- and pip does not fall back to an
    unverified download: a `--hash` that does not match is a hard error, so the
    bump would leave a file nobody can install from. That is the same verdict
    the lockfile half reaches about an edited manifest beside a stale lock."""
    if "--hash" not in opts:
        return ""
    return ("this requirement is pinned by digest (%s), and those digests "
            "describe the release being replaced. Nothing here recomputes them "
            "-- re-run pip-compile -- and pip rejects a requirements file whose "
            "hashes do not match, so the version is not moved on its own"
            % _oneline(opts)[:80])


PARSERS = {"yaml": _parse_yaml, "toml": tomllib.loads, "json": _parse_json,
           "requirements": parse_requirements}


def parse(manager, text):
    """This file's meaning, by the real parser for its format.

    A leading BOM is dropped first, and on BOTH sides of the comparison, so it
    can neither hide the document from the parser nor show up as a change. It is
    an encoding artefact of the byte stream rather than a member of any of these
    grammars -- tomllib and json reject it outright -- and no TOML, JSON or YAML
    construct can span it, so removing it cannot move a value.

    EVERY failure of a parser comes back as Unreadable, named. These parsers are
    handed a file this tool did not write, and a parser that raises something
    else -- a RecursionError on a deeply nested value, whatever a future PyYAML
    decides to raise -- would otherwise travel past the caller that owns the
    rollback. Naming the exception in the refusal is not swallowing it: the run
    ends, and it ends saying exactly what the parser said."""
    kind = FORMATS.get(manager)
    if kind is None:
        raise Unreadable(
            "there is no real parser here for manager '%s', and a file whose "
            "meaning cannot be read back is not written" % manager)
    body = text[1:] if text.startswith(BOM) else text
    try:
        return PARSERS[kind](body)
    except Unreadable:
        raise
    except RecursionError as exc:
        raise Unreadable(
            "it nests too deeply for the %s parser to read: %s"
            % (kind, _oneline(exc))) from exc
    except Exception as exc:                       # noqa: BLE001 -- see above
        raise Unreadable("it does not read as %s: %s: %s"
                         % (kind, type(exc).__name__, _oneline(exc))) from exc


def flatten(struct):
    """Every path in the document, and what sits at it.

    A scalar contributes its type and its value, so YAML's `1` and `true` are
    not one leaf. A container contributes its SHAPE -- a mapping's key set, a
    sequence's length -- which is what makes a key added, a key removed or an
    emptied collection visible as a change at the container itself, on top of
    the paths that appear or disappear underneath it.

    ITERATIVE, and not as a matter of taste. The recursive version died on a
    document 1200 levels deep -- which json parses without complaint -- and the
    RecursionError travelled out of audit(), past the rollback, and left the
    hostile write on disk. The stack here is the document's, not python's, so
    the only ceilings are the declared ones: MAX_DEPTH, which also bounds the
    cost of the self-reference check (a YAML alias can make a node its own
    descendant), and MAX_PATHS. Both are refusals, never a partial answer."""
    out = {}
    stack = [(struct, (), ())]
    while stack:
        node, path, seen = stack.pop()
        if not isinstance(node, (dict, list)):
            out[path] = (type(node).__name__, node)
            continue
        if id(node) in seen:
            raise Unreadable(
                "%s refers back to itself, so this document has no finite set "
                "of paths to compare" % show(path))
        if len(seen) >= MAX_DEPTH:
            # The path is elided: at this depth writing it out in full is a
            # 700-character plan row that says nothing the first few segments
            # do not.
            raise Unreadable(
                "this document nests past %d levels, under %s; it is not "
                "compared rather than compared partially"
                % (MAX_DEPTH, show(path[:4]) + " ..."))
        if len(out) > MAX_PATHS:
            raise Unreadable(
                "this document expands past %d paths; it is not compared rather "
                "than compared partially" % MAX_PATHS)
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


def show(path):
    """A path as a human reads it: `jobs.build.steps[0].uses`."""
    out = ""
    for part in path:
        if isinstance(part, int):
            out += "[%d]" % part
        else:
            out += ("." + str(part)) if out else str(part)
    return out or "(the document root)"


def _paths(paths):
    return ", ".join(sorted(show(path) for path in paths)) or "(none)"


# --------------------------------------------------------------------------
# Where each manager DECLARES a dependency, read off the parsed document
# --------------------------------------------------------------------------
# These walk dicts and lists, not text. Every question the locator has to answer
# with a regex -- is this `uses:` a step's or a `with:` input's, is this line
# inside a block scalar, is this `[dependencies]` cargo's or
# `[package.metadata]`'s, did an anchor swallow the mapping under it -- has
# already been answered by the real parser by the time these run.
def _mapping(node):
    return node if isinstance(node, dict) else {}


def _sequence(node):
    return node if isinstance(node, list) else []


def _whole(path, text):
    """A Decl over the whole of a string leaf: pub, npm and cargo state the
    version in theirs and nothing else."""
    return Decl(path, text, 0, len(text))


def _step_nodes(struct):
    """(path, mapping) for every place a github-actions `uses:` may sit: a job
    itself (a reusable workflow call), a job's steps, and a composite action's
    steps. Nowhere else -- a `with:` input named `uses` is an input, and a
    workflow printed inside a `run:` block is a string."""
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


def _uses(path, node, want):
    """The Decl for one `uses:`, when it names this action. The name is
    everything before the LAST `@`, which is what keeps `actions/checkout` and
    `actions/checkout-extra` apart."""
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


def decl_actions(struct, dep):
    want = dep.casefold()
    found = (_uses(path, node, want) for path, node in _step_nodes(struct))
    return [decl for decl in found if decl is not None]


def decl_pub(struct, dep):
    """The dep's key in a top-level pubspec dependency section. A dep spelled as
    a MAP -- `hosted:` with the version nested under it, `sdk: flutter`, a path
    dependency -- states no version in one scalar and is not a declaration
    here, which is the same verdict the locator reaches on that shape."""
    root = _mapping(struct)
    return [_whole((section, dep), root[section][dep])
            for section in renovate_locator.PUB_SECTIONS
            if isinstance(_mapping(root.get(section)).get(dep), str)]


def decl_precommit(struct, dep):
    out = []
    want = dep.casefold()
    for i, item in enumerate(_sequence(_mapping(struct).get("repos"))):
        if not isinstance(item, dict) or not isinstance(item.get("rev"), str):
            continue
        if renovate_locator.repo_name(str(item.get("repo", ""))) == want:
            out.append(_whole(("repos", i, "rev"), item["rev"]))
    return out


def _dig(struct, path):
    node = struct
    for part in path:
        node = _mapping(node).get(part)
    return node


def _array(out, array, path, want):
    """Every PEP 508 string in one dependency array that names `want`."""
    for i, text in enumerate(_sequence(array)):
        if not isinstance(text, str):
            continue
        parsed = renovate_locator.pep508_span(text)
        if parsed is None or renovate_locator.normalise(parsed[0]) != want:
            continue
        out.append(Decl(path + (i,), text, parsed[2], parsed[3]))


def decl_pep621(struct, dep):
    """The specifier inside every quoted PEP 508 string naming this dep, in a
    table that actually declares dependencies. The table set is the locator's
    own, so `[project] keywords` is not one here either -- but which table a
    line is IN is decided by tomllib rather than by tracking headers."""
    out = []
    want = renovate_locator.normalise(dep)
    for table, keys in renovate_locator.PEP621_KEYS.items():
        for key in keys:
            _array(out, _mapping(_dig(struct, table)).get(key),
                   table + (key,), want)
    for table in renovate_locator.PEP621_TABLES:
        for key, array in _mapping(_dig(struct, table)).items():
            _array(out, array, table + (key,), want)
    return out


def _cargo_roots(struct):
    """Every mapping whose `[dependencies]` is cargo's own: the manifest root,
    `[workspace]`, and each `[target.<cfg>]`. `[package.metadata]` is not among
    them, so a `dependencies` table under it is not a dependency table."""
    root = _mapping(struct)
    yield (), root
    if isinstance(root.get("workspace"), dict):
        yield ("workspace",), root["workspace"]
    for cfg, node in _mapping(root.get("target")).items():
        if isinstance(node, dict):
            yield ("target", cfg), node


def decl_cargo(struct, dep):
    """The crate's entry in a dependency table, as a bare string or as the
    `version` key of its table. A `{ workspace = true }` entry states no version
    HERE and is not a declaration: the version it inherits lives in
    `[workspace.dependencies]`, which is a different path in this same walk."""
    out = []
    for base, node in _cargo_roots(struct):
        for table in renovate_locator.CARGO_TABLES:
            spec = _mapping(node.get(table)).get(dep)
            if isinstance(spec, str):
                out.append(_whole(base + (table, dep), spec))
            elif isinstance(_mapping(spec).get("version"), str):
                out.append(_whole(base + (table, dep, "version"),
                                  spec["version"]))
    return out


def decl_npm(struct, dep):
    root = _mapping(struct)
    return [_whole((obj, dep), root[obj][dep])
            for obj in renovate_locator.NPM_OBJECTS
            if isinstance(_mapping(root.get(obj)).get(dep), str)]


def decl_requirements(struct, dep):
    """Every requirement naming this dep, its specifier the value that moves --
    unless the digests glued after it say it may not move at all."""
    want = renovate_locator.normalise(dep)
    out = []
    for i, entry in enumerate(_sequence(struct)):
        if entry.get("name") is None:
            continue
        if renovate_locator.normalise(entry["name"]) != want:
            continue
        spec = entry["spec"]
        out.append(Decl((i, "spec"), spec, 0, len(spec),
                        hash_pinned(entry["opts"])))
    return out


DECLARERS = {
    "github-actions": decl_actions,
    "pub": decl_pub,
    "pre-commit": decl_precommit,
    "pep621": decl_pep621,
    "cargo": decl_cargo,
    "npm": decl_npm,
    "pip_requirements": decl_requirements,
    "pip-compile": decl_requirements,
}


# --------------------------------------------------------------------------
# The invariant, computed before the edit and checked after it
# --------------------------------------------------------------------------
def _miscount(dep, old, count, found, at_old):
    """Why a real parse and the report do not agree about this dependency.

    Three different disagreements, said three different ways, because the reader
    has to know which one it is: a file that declares the dep nowhere, a file
    that declares it somewhere else, and a file that declares it in more places
    than the report accounts for."""
    where = ", ".join("%s=%s" % (show(d.path), d.leaf[d.start:d.end])
                      for d in found)
    if not found:
        return ("a real parser finds no declaration of '%s' in this file at "
                "all, so whatever line was picked to rewrite is not one; "
                "nothing is written" % dep)
    if not at_old:
        return ("a real parser reads this file as declaring '%s' at %s, and "
                "none of those carries the reported current value %s -- "
                "something moved, so nothing is written" % (dep, where, old))
    return ("a real parser reads this file as declaring '%s' at %s -- %d of "
            "them at the reported %s, against %d update(s) in the report. "
            "Which declaration the report means is not knowable from the "
            "file, so nothing is written"
            % (dep, where, len(at_old), old, count))


def _crashed(doing, exc):
    """A refusal naming an exception nothing here expected.

    Not a swallow: the string is a refusal, so the run ends and the file goes
    back. What it replaces is a traceback thrown PAST the caller that owns the
    rollback -- measured, and the reason this module's two entry points are
    total. The type and the message are printed because the next reader of this
    line has to be able to fix what raised."""
    return ("%s raised %s: %s. That is a defect in the auditor rather than a "
            "verdict on the file, and an audit that cannot finish does not "
            "sanction an edit -- so nothing is kept"
            % (doing, type(exc).__name__, _oneline(exc)))


def _expected(manager, text, groups):
    struct = parse(manager, text)
    leaves = flatten(struct)
    want = {}
    for dep, old, new, count in groups:
        found = DECLARERS[manager](struct, dep)
        at_old = [d for d in found if d.leaf[d.start:d.end] == old]
        if len(at_old) != count:
            return {}, {}, _miscount(dep, old, count, found, at_old)
        for decl in at_old:
            # A declaration the parser reads perfectly well and still will not
            # let this tool move. It is not a miscount and not an unreadable
            # file, so it says its own reason.
            if decl.why:
                return {}, {}, "%s declares '%s', and %s" % (
                    show(decl.path), dep, decl.why)
            if decl.path in want:
                return {}, {}, (
                    "two of this report's updates both claim %s; one value "
                    "cannot become two things" % show(decl.path))
            rewritten = decl.leaf[:decl.start] + new + decl.leaf[decl.end:]
            # A report whose old and new are the SAME string is a lockfile-only
            # update: the range already covers the release, so writing it is a
            # no-op whose only job is to register the lockfile refresh. `want`
            # is the set of paths the write MUST MOVE, so a no-op path is not
            # one -- including it here made --apply refuse every cargo manifest
            # with an in-range patch available (measured 2026-09-11).
            if rewritten != decl.leaf:
                want[decl.path] = rewritten
    return want, leaves, ""


def expected(manager, text, groups):
    """(path -> the leaf that path must carry after the edit, this document's
    leaves, a refusal).

    `groups` is one entry per reported pin: (dep, old, new, count). The paths
    come from the PARSE, never from the locator -- that is the whole point. A
    group whose declaration count does not match the report's is a refusal
    rather than a guess, and so is a document that cannot be parsed at all.

    Total, by construction: every failure leaves here as the third element."""
    try:
        return _expected(manager, text, groups)
    except Unreadable as exc:
        return {}, {}, str(exc)
    except Exception as exc:                       # noqa: BLE001 -- see _crashed
        return {}, {}, _crashed("working out what the edit may change", exc)


def _shape(gone, born):
    """A version bump adds and removes nothing. Anything that does is either a
    value that escaped its own quoting -- a reported newValue carrying a `"` in
    a package.json wrote a second key -- or a line rewritten into something the
    format reads differently."""
    parts = []
    if gone:
        parts.append("%d path(s) disappeared (%s)" % (len(gone), _paths(gone)))
    if born:
        parts.append("%d appeared (%s)" % (len(born), _paths(born)))
    return ("the edit changed the SHAPE of the file: " + " and ".join(parts)
            + ". A version bump adds and removes nothing")


def _elsewhere(moved, want):
    stray = moved - set(want)
    missed = set(want) - moved
    parts = []
    if stray:
        parts.append("it changed %s, which declares nothing this report names"
                     % _paths(stray))
    if missed:
        parts.append("it left %s, the declaration the report named, alone"
                     % _paths(missed))
    return ("the edit did not land where the report's dependency is declared: "
            + "; and ".join(parts))


def audit(manager, before_text, after_text, groups):
    """"" when the edit changed exactly the declarations the report named, from
    the old value to the new one, and nothing else in the document; otherwise
    the reason to put the file back.

    This is the check the safety rests on, and it does not consult the locator:
    both sides are parsed for real, and the paths allowed to move were worked
    out from the BEFORE parse. A locator that picked the wrong line writes a
    change at a path this function did not sanction, and gets caught for that
    alone.

    Total, like expected(), and for a harder reason: this is the function whose
    verdict triggers the rollback, so one that raises takes the rollback with
    it. Measured 2026-09-10 -- a newValue nesting 1200 arrays deep left the
    hostile write on disk. renovate_planner.py ALSO rolls back on an exception
    from here, because the rollback must not rest on this function's own
    correctness."""
    try:
        return _audit(manager, before_text, after_text, groups)
    except Exception as exc:                       # noqa: BLE001 -- see _crashed
        return _crashed("auditing the file after the write", exc)


def _audit(manager, before_text, after_text, groups):
    want, before_leaves, why = expected(manager, before_text, groups)
    if why:
        return why
    try:
        after_leaves = flatten(parse(manager, after_text))
    except Unreadable as exc:
        return "after the edit, %s" % exc
    gone = set(before_leaves) - set(after_leaves)
    born = set(after_leaves) - set(before_leaves)
    if gone or born:
        return _shape(gone, born)
    moved = {p for p in before_leaves if before_leaves[p] != after_leaves[p]}
    if moved != set(want):
        return _elsewhere(moved, want)
    for path in sorted(moved, key=show):
        if after_leaves[path] != ("str", want[path]):
            return ("%s now reads %r, and the reported update makes it %r"
                    % (show(path), after_leaves[path][1], want[path]))
    return ""
