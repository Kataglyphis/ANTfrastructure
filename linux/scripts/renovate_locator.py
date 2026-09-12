#!/usr/bin/env python3
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
"""Where a dependency is DECLARED, read in the manager's own syntax.

This module answers exactly one question, and answers it structurally: given a
manager, a file's lines and a dependency NAME, which lines DECLARE that
dependency, and what value does each declaration carry?

It never searches for the old value. The previous locator did -- it found the
old value anywhere in the file and then "narrowed" by proximity to a line that
merely mentioned the dep -- and it wrote `other_pkg: 1.6.0` into a pubspec whose
report named only `http`, walked a workflow's steps one per run, matched `http`
inside `http_parser`, and let a dep named in a COMMENT anchor an unrelated pin.
Every one of those is a text search dressed up as a match, so there is no text
search here at all: each finder parses the shape its manager defines, anchors on
the dependency name as that shape spells it, and returns the exact character
span of the value. A manager with no finder gets None, which the caller must
turn into a refusal -- never a fallback.

Two rules keep a finder honest, and both were bought with a wrong write:

  * a line that LOOKS like a declaration in text but is not one in the syntax --
    a `uses:` printed inside a `run: |` block, a `with:` input named `uses`, a
    `[package.metadata.dependencies]` table, a `"left-pad"` in an array -- is
    not a site. Every finder here parses structure, not lines.
  * a declaration whose value this module cannot read is a REFUSAL, never a
    fallback to some other site. A pubspec declaring `http` as a `hosted:` map
    used to end with the `dependency_overrides` entry rewritten instead.

The public entry points are sites() (the declarations) and resolve() (the
verdict for one group of report rows). The prose lives in
docs/dependency-updates.md#how-one-value-gets-rewritten.
"""
import collections
import re

# line: 0-based index into the lines handed in. start/end: the half-open span of
# the VALUE inside that line, so a rewrite is line[:start] + new + line[end:] and
# touches nothing else on the line -- no comment, no marker, no quoting.
Site = collections.namedtuple("Site", "line start end value")
# One `key: value` line. `col` is the column the KEY starts at, which is what
# decides nesting: a line indented past it is inside this key, a line at or
# before it has left it.
Key = collections.namedtuple("Key", "name col start value")

_DASH = re.compile(r"^(\s*)-\s+(?=\S)")
_YAML_KEY = re.compile(r"^\s*(?:-\s+)?([A-Za-z0-9_./\-]+)\s*:(?=\s|$)")
_BLOCK = re.compile(r"^[|>][+-]?\d*$")
_TOML_TABLE = re.compile(r"^\s*\[\[?([^\]]+)\]\]?\s*$")
_TOML_KV = re.compile(r"""^\s*(?:"([^"]+)"|'([^']+)'|([A-Za-z0-9_.\-]+))\s*=\s*""")
_INLINE_VERSION = re.compile(r"""version\s*=\s*"([^"]*)\"""")
_QUOTED = re.compile(r""""((?:[^"\\]|\\.)*)"|'((?:[^'\\]|\\.)*)'""")
_PEP508_NAME = re.compile(r"^\s*([A-Za-z0-9][A-Za-z0-9._\-]*)\s*(\[[^\]]*\])?\s*")

PUB_SECTIONS = ("dependencies", "dev_dependencies", "dependency_overrides")
CARGO_TABLES = ("dependencies", "dev-dependencies", "build-dependencies")
NPM_OBJECTS = ("dependencies", "devDependencies", "optionalDependencies",
               "peerDependencies", "resolutions", "overrides")


def normalise(name):
    """A PEP 503 project name: `-`, `_` and `.` runs collapse, case folds.
    "Foo_Bar", "foo-bar" and "foo.bar" are ONE name to pip, so a report saying
    foo-bar must find the line spelling it Foo_Bar."""
    return re.sub(r"[-_.]+", "-", name.strip()).lower()


def pep508_span(text):
    """(name, extras, start, end) for one PEP 508 requirement, or None.

    `start`/`end` are the half-open span of the version SPECIFIER inside `text`,
    the environment marker excluded: `ruff==0.9.0 ; sys_platform=="linux"`
    yields ("ruff", "", 4, 11), so a rewrite of the specifier cannot disturb the
    marker beside it. One owner, because three callers need exactly this answer
    -- the requirements finder, the pyproject one, and renovate_audit.py reading
    the same requirement back off a real parse."""
    match = _PEP508_NAME.match(text)
    if not match:
        return None
    spec = text[match.end():].split(";", 1)[0]
    lead = len(spec) - len(spec.lstrip())
    start = match.end() + lead
    return match.group(1), match.group(2) or "", start, start + len(spec.strip())


def uncomment(line, quotes=""):
    """`line` truncated at the first comment marker that is neither inside a
    quoted string nor glued to a non-blank character. The second half matters:
    `uses: some/action@v1#frag` carries no comment, while `pkg==1.0  # note`
    does, and a naive split on "#" cannot tell them apart."""
    quote = ""
    escaped = False
    for i, char in enumerate(line):
        if escaped:
            escaped = False
        elif quote:
            if char == "\\":
                escaped = True
            elif char == quote:
                quote = ""
        elif char in quotes:
            quote = char
        elif char == "#" and (i == 0 or line[i - 1] in " \t"):
            return line[:i]
    return line


def _indent(line):
    return len(line) - len(line.lstrip(" "))


def _key_value(line, quotes="\"'"):
    """The Key on a `key: value` line, or None. The value is stripped and its
    start is an index into `line`, so the span is exact."""
    match = _YAML_KEY.match(line)
    if not match:
        return None
    body = uncomment(line[match.end():], quotes)
    lead = len(body) - len(body.lstrip())
    return Key(match.group(1), match.start(1), match.end() + lead, body.strip())


def _unquote(value, start):
    """A YAML scalar with its surrounding quotes removed, span adjusted."""
    if len(value) >= 2 and value[0] in "\"'" and value[-1] == value[0]:
        return value[1:-1], start + 1
    return value, start


def _site(line_no, start, value):
    return Site(line_no, start, start + len(value), value)


def _blank_or_comment(line):
    stripped = line.strip()
    return not stripped or stripped.startswith("#")


# --------------------------------------------------------------------------
# One YAML walk, three managers
# --------------------------------------------------------------------------
def _open_node(nodes, stack, name, col):
    """Push a new mapping at `col`, closing everything it dedents out of."""
    while len(stack) > 1 and stack[-1]["col"] >= col:
        stack.pop()
    node = {"name": name, "col": col, "parent": stack[-1], "at": {}}
    nodes.append(node)
    stack.append(node)


def yaml_nodes(lines):
    """Every mapping the document opens, each carrying its OWN keys as Sites.

    A mapping is the document root, a `key:` with nothing after the colon, or a
    `- ` sequence item; a key belongs to the innermost mapping whose column is
    smaller than the key's. That is the only thing that tells a step's `uses:`
    apart from a `uses:` sitting in that step's `with:` inputs, tells a pubspec
    dependency apart from a key nested under one, and tells two pre-commit
    hooks pinned to the same `rev:` apart from each other.

    The open mappings are a STACK, not one `current`: a `hooks:` list nested
    inside a repo item is itself a sequence, and treating its first `- id:` as
    the end of the enclosing item lost every key written after it. pre-commit
    puts no order on a repo's keys, so a config spelling `hooks:` before `rev:`
    would have looked like a repo with no rev at all.

    A `|` or `>` block scalar is TEXT, and every line of it is skipped. A step
    that PRINTS a workflow -- `run: |` with `- uses: actions/checkout@v4`
    inside it -- was read as a step of its own and rewritten."""
    root = {"name": "", "col": -1, "parent": None, "at": {}}
    nodes = [root]
    stack = [root]
    block = None
    for num, line in enumerate(lines):
        if block is not None:
            if not line.strip() or _indent(line) > block:
                continue
            block = None
        if _blank_or_comment(line):
            continue
        if _DASH.match(line):
            _open_node(nodes, stack, "-", _indent(line))
        parsed = _key_value(line)
        if parsed is None:
            continue
        while len(stack) > 1 and stack[-1]["col"] >= parsed.col:
            stack.pop()
        value, start = _unquote(parsed.value, parsed.start)
        stack[-1]["at"][parsed.name] = _site(num, start, value)
        if not value:
            _open_node(nodes, stack, parsed.name, parsed.col)
        elif _BLOCK.match(value):
            block = parsed.col
    return nodes


def _named(node, name):
    return node["parent"] is not None and node["parent"]["name"] == name


# --------------------------------------------------------------------------
# github-actions
# --------------------------------------------------------------------------
def find_actions(lines, dep, _dep_type):
    """The `ref` of every step or job `uses:` whose value names this action.

    A step is `uses: <owner>/<repo>[/<path>]@<ref>`, so the name is everything
    before the LAST "@" and the value is everything after it. Splitting there is
    what separates `actions/checkout` from `actions/checkout-extra`: the two
    produce different names, and a substring test cannot.

    WHICH `uses:` counts is the other half, and it is a question about the
    document, not the line. A step's `uses:` is a key of a sequence item; a
    reusable workflow's is a key of a job (`jobs.<id>.uses`). A `uses:` sitting
    anywhere else -- an input named `uses` under a step's `with:`, a line inside
    a `run: |` block that prints a workflow -- is not an action reference, and
    both of those were being rewritten."""
    out = []
    want = dep.casefold()
    for node in yaml_nodes(lines):
        site = node["at"].get("uses")
        if site is None or not (node["name"] == "-" or _named(node, "jobs")):
            continue
        repo, at, ref = site.value.rpartition("@")
        if not at:
            continue
        folded = repo.casefold()
        if folded != want and not folded.startswith(want + "/"):
            continue
        out.append(_site(site.line, site.start + len(repo) + 1, ref))
    return out


# --------------------------------------------------------------------------
# pub (pubspec.yaml)
# --------------------------------------------------------------------------
def find_pub(lines, dep, _dep_type):
    """The constraint of a key that IS this dep, in a top-level dependency
    section of the pubspec.

    Anchoring on the whole key is what keeps `http` off `http_parser`, and
    reading the document's mappings is what keeps `sdk: flutter` (a key nested
    under a dep) and the `assets:` list under `flutter:` out of the candidate
    set entirely. A dep declared as a nested map -- `hosted:` with a `version:`
    below it, or `sdk: flutter` -- has an EMPTY value here, and resolve()
    refuses on it rather than reaching for another section that happens to name
    the same dep."""
    out = []
    for node in yaml_nodes(lines):
        if node["name"] not in PUB_SECTIONS or not _named(node, ""):
            continue
        site = node["at"].get(dep)
        if site is not None:
            out.append(site)
    return out


# --------------------------------------------------------------------------
# pip_requirements
# --------------------------------------------------------------------------
def _requirement_body(line):
    """One physical line, ready to be read as a requirement.

    pip joins a line ending in `\\` onto the next one, and `pip-compile
    --generate-hashes` writes exactly that: `ruff==0.9.0 \\` and then a line of
    `--hash=sha256:...`. The specifier still sits WHOLE on this line -- the
    continuation carries options, never the version -- but the backslash was
    being read as part of it, so the value came back as `==0.9.0 \\`, matched no
    reported current value, and the file was refused with the wrong reason
    ("something moved") for a pin that had not moved at all. Trimming the marker
    off the tail cannot disturb the span of anything before it.

    A continuation carrying the version instead (`ruff \\` / `  ==0.9.0`) leaves
    no specifier on this line, which comes back as a valueless site and is
    refused by resolve() -- the same verdict every unreadable declaration gets.
    """
    body = uncomment(line)
    stripped = body.rstrip()
    return stripped[:-1] if stripped.endswith("\\") else body


def find_requirements(lines, dep, _dep_type):
    """The specifier of every PEP 508 line whose NAME normalises to this dep.

    Names normalise per PEP 503, so a report saying "foo-bar" finds "Foo_Bar".
    An option line (-e, -r, --hash) is not a requirement and is skipped; so is a
    comment, which is what kept `# ruff is managed by renovate` from anchoring
    the `black==0.9.0` below it."""
    out = []
    want = normalise(dep)
    for num, line in enumerate(lines):
        body = _requirement_body(line)
        if not body.strip() or body.lstrip().startswith("-"):
            continue
        parsed = pep508_span(body)
        if parsed is None or normalise(parsed[0]) != want:
            continue
        out.append(Site(num, parsed[2], parsed[3], body[parsed[2]:parsed[3]]))
    return out


# --------------------------------------------------------------------------
# pep621 (pyproject.toml)
# --------------------------------------------------------------------------
# The arrays a PEP 621 dependency may live in, by table path. Anything else is
# not a dependency array, and a string in it is not a requirement -- measured
# against OrchestrANT's pyproject.toml, where `keywords = [..., "onnxruntime",
# ...]` under [project] was read as a pin of onnxruntime by the first cut of
# this finder. A table not listed here yields no site, so the caller refuses by
# name instead of editing a keyword.
PEP621_KEYS = {
    ("project",): ("dependencies",),
    ("build-system",): ("requires",),
    ("tool", "uv"): ("dev-dependencies", "constraint-dependencies",
                     "override-dependencies"),
}
PEP621_TABLES = (("project", "optional-dependencies"),
                 ("dependency-groups",),
                 ("tool", "pdm", "dev-dependencies"))


def _is_dep_array(path, key):
    table = tuple(path)
    return table in PEP621_TABLES or key in PEP621_KEYS.get(table, ())


def _bracket_delta(body):
    """`[` minus `]`, counting only brackets OUTSIDE a quoted string, so a URL
    or a marker carrying a bracket cannot close the array early."""
    depth = 0
    quote = ""
    escaped = False
    for char in body:
        if escaped:
            escaped = False
        elif quote:
            if char == "\\":
                escaped = True
            elif char == quote:
                quote = ""
        elif char in "\"'":
            quote = char
        elif char == "[":
            depth += 1
        elif char == "]":
            depth -= 1
    return depth


def _pep508_sites(body, num, want):
    """Every quoted PEP 508 requirement on this line whose name is `want`."""
    out = []
    for match in _QUOTED.finditer(body):
        text = match.group(1) if match.group(1) is not None else match.group(2)
        parsed = pep508_span(text)
        if parsed is None or normalise(parsed[0]) != want:
            continue
        at = match.start() + 1
        out.append(Site(num, at + parsed[2], at + parsed[3],
                        text[parsed[2]:parsed[3]]))
    return out


def find_pep621(lines, dep, _dep_type):
    """The specifier inside every quoted PEP 508 string naming this dep, in a
    table that actually declares dependencies.

    A pyproject dependency is a STRING inside a known array, so the parse starts
    from the table header and then from the string -- which is what keeps `torch`
    off `"torchvision==0.28.0"`, off the commented-out `#"dearpygui==2.2.0"` and
    off a `keywords` entry that happens to be a package name. A dep declared in
    several extras yields several sites, which the caller resolves by COUNT
    rather than by picking one."""
    out = []
    want = normalise(dep)
    path = []
    depth = 0
    for num, line in enumerate(lines):
        body = uncomment(line, "\"'").rstrip()
        table = _TOML_TABLE.match(body)
        if table:
            path = toml_path(table.group(1))
            depth = 0
            continue
        assign = _TOML_KV.match(body)
        if assign and depth <= 0:
            name = assign.group(1) or assign.group(2) or assign.group(3)
            if not _is_dep_array(path, name):
                continue
            depth = 0
        elif depth <= 0:
            continue
        out.extend(_pep508_sites(body, num, want))
        depth += _bracket_delta(body)
    return out


# --------------------------------------------------------------------------
# pre-commit
# --------------------------------------------------------------------------
def repo_name(url):
    """`owner/repo`, the depName Renovate gives a pre-commit `repo:`. Returns ""
    for `local`, `meta` and anything else that is not a hosted repository."""
    text = re.sub(r"\.git$", "", url.strip().strip("\"'"))
    text = re.sub(r"^[A-Za-z][A-Za-z0-9+.\-]*://", "", text)
    text = re.sub(r"^[^/]*@", "", text)
    parts = [p for p in text.replace(":", "/").split("/") if p]
    if len(parts) < 3:
        return ""
    return "/".join(parts[-2:]).casefold()


def find_precommit(lines, dep, _dep_type):
    """The `rev:` of the sequence item whose own `repo:` names this dep, and no
    other item's."""
    want = dep.casefold()
    return [node["at"]["rev"] for node in yaml_nodes(lines)
            if node["name"] == "-" and "rev" in node["at"]
            and "repo" in node["at"]
            and repo_name(node["at"]["repo"].value) == want]


# --------------------------------------------------------------------------
# cargo
# --------------------------------------------------------------------------
def toml_path(header):
    """The dotted table path of a `[a.b.c]` header, quoted segments unquoted."""
    out = []
    current = ""
    quote = ""
    for char in header:
        if quote:
            if char == quote:
                quote = ""
            else:
                current += char
        elif char in "\"'":
            quote = char
        elif char == ".":
            out.append(current.strip())
            current = ""
        else:
            current += char
    out.append(current.strip())
    return [part for part in out if part]


def _toml_key(line, num, key):
    """The Site of `key = <value>` on this line, value UNPARSED, or None."""
    body = uncomment(line, "\"'")
    match = _TOML_KV.match(body)
    if not match:
        return None
    name = match.group(1) or match.group(2) or match.group(3)
    if name != key:
        return None
    rest = body[match.end():]
    lead = len(rest) - len(rest.lstrip())
    return _site(num, match.end() + lead, rest.strip())


def _cargo_value(site):
    """A cargo requirement is either the bare string `"1.0"` or the `version`
    key of an inline table; both are narrowed to the version's own span so a
    rewrite cannot disturb the features list beside it. An inline table with no
    `version` key states no version HERE, and comes back empty."""
    text = site.value
    if len(text) >= 2 and text[0] in "\"'" and text[-1] == text[0]:
        return Site(site.line, site.start + 1, site.end - 1, text[1:-1])
    match = _INLINE_VERSION.search(text) if text.startswith("{") else None
    if match:
        return _site(site.line, site.start + match.start(1), match.group(1))
    return Site(site.line, site.start, site.end, "")


def _cargo_table(path):
    """(table, crate) when this TOML table path IS a cargo dependency table,
    else None. `crate` is set only for a table that belongs to one crate,
    `[dependencies.serde]`.

    A dependency table is `[dependencies]`, `[dev-dependencies]` or
    `[build-dependencies]`, optionally under `[workspace.…]` or
    `[target.<cfg>.…]`, and optionally one segment deeper for a single crate.
    Testing the LAST segment alone -- what this did first -- read
    `[package.metadata.dependencies]` as a real dependency table and rewrote a
    key in it."""
    parts = list(path)
    if parts[:1] == ["workspace"]:
        parts = parts[1:]
    elif parts[:1] == ["target"] and len(parts) > 2:
        parts = parts[2:]
    if not parts or parts[0] not in CARGO_TABLES or len(parts) > 2:
        return None
    return parts[0], parts[1] if len(parts) == 2 else None


def find_cargo(lines, dep, _dep_type):
    """A key in a dependency table, or the `version` of `[dependencies.<dep>]`.

    Both spellings are the same declaration, and the table path is what says
    which one this line is -- so `serde_json` in [dependencies] is never read as
    `serde`, and neither `[package.metadata]` nor `[package.metadata.
    dependencies]` is a dependency table at all.

    A declaration that states no version HERE is not a site: `clap = { workspace
    = true }` delegates to `[workspace.dependencies]`, and a path or git
    dependency has no version to move. Returning those as empty sites is what
    made a workspace member's second `--apply` REFUSE instead of reporting
    `already applied` -- the version had moved in the workspace table, and the
    valueless member line still counted against the file."""
    out = []
    path = []
    for num, line in enumerate(lines):
        # uncomment FIRST: `[dependencies]  # the app's own` is still a table
        # header, and matching the raw line demands "]" at end of line.
        table = _TOML_TABLE.match(uncomment(line, "\"'"))
        if table:
            path = toml_path(table.group(1))
            continue
        where = _cargo_table(path)
        if where is None:
            continue
        if where[1] is None:
            site = _toml_key(line, num, dep)
        elif where[1] == dep:
            site = _toml_key(line, num, "version")
        else:
            continue
        if site is None:
            continue
        stated = _cargo_value(site)
        if stated.value:
            out.append(stated)
    return out


# --------------------------------------------------------------------------
# npm
# --------------------------------------------------------------------------
def _json_string_end(text, start):
    """The index of the quote closing the JSON string that opens at `start`."""
    i = start + 1
    while i < len(text):
        if text[i] == "\\":
            i += 2
        elif text[i] == '"':
            return i
        else:
            i += 1
    return len(text)


def json_strings(text):
    """Every string VALUE in a JSON document, as (path, line, column, text).

    `path` is the tuple of keys enclosing the value, None standing for an array
    element, so `("dependencies", "left-pad")` is a top-level dependency while
    `("scripts", "left-pad")` and `("keywords", None)` are not.

    A scanner rather than json.loads, because the whole answer here is WHERE the
    value sits and json throws the position away. And a scanner rather than
    line-shaped regexes, because those cannot track structure: the first cut
    popped its object stack on every `]` without ever pushing on `[`, so an
    array silently closed the object around it, and a manifest written on one
    line was invisible to it."""
    out = []
    stack = []
    expect_key = False
    line = 0
    bol = 0
    i = 0
    while i < len(text):
        char = text[i]
        if char == "\n":
            line += 1
            i += 1
            bol = i
        elif char in "{[":
            stack.append({"kind": char, "key": None})
            expect_key = char == "{"
            i += 1
        elif char in "}]":
            if stack:
                stack.pop()
            expect_key = False
            i += 1
        elif char == '"':
            end = _json_string_end(text, i)
            if expect_key and stack:
                stack[-1]["key"] = text[i + 1:end]
            else:
                out.append((tuple(f["key"] for f in stack), line,
                            i + 1 - bol, text[i + 1:end]))
            i = end + 1
        else:
            if char == ",":
                expect_key = bool(stack) and stack[-1]["kind"] == "{"
            elif char == ":":
                expect_key = False
            i += 1
    return out


def find_npm(lines, dep, _dep_type):
    """The value of the dep's key in a TOP-LEVEL dependencies object.

    JSON has no comments, but it has plenty of ambiguity about what a key IS:
    the same `"left-pad"` is a dependency in one object, a script name in
    another, a string in a `keywords` array, and a key of a nested `overrides`
    sub-object. Only the full path decides, so the document is scanned and the
    path compared. A dependencies object that is not a top-level key of
    package.json -- a nested override, an object inside some array -- is a form
    this locator does not read: it yields nothing, and the caller refuses by
    name rather than writing the wrong `"left-pad"`."""
    out = []
    for path, num, col, text in json_strings("\n".join(lines)):
        if len(path) == 2 and path[0] in NPM_OBJECTS and path[1] == dep:
            out.append(_site(num, col, text))
    return out


# --------------------------------------------------------------------------
# custom.regex over an annotated env file
# --------------------------------------------------------------------------
# The hint the customManager reads: `# renovate: datasource=... depName=<name>`.
# The depName it names is the anchor; the declaration is the KEY= line under it,
# or under the `# noforward` line the same regex allows in between.
_ENV_ANN = re.compile(r"^# renovate:.*?\bdepName=(\S+)(?:\s|$)")
_ENV_KV = re.compile(r"^([A-Z0-9_]+)=([^\s#]*)$")


def find_annotated_env(lines, dep, _dep_type):
    """The value of the KEY= line under the hint naming this dependency.

    A hint with no readable KEY= line under it is not a site at all, so the
    caller refuses rather than rewriting a neighbouring declaration. Two hints
    naming the same dep yield two sites, and the count rule decides."""
    out = []
    for num, line in enumerate(lines):
        match = _ENV_ANN.match(line)
        if match is None or match.group(1) != dep:
            continue
        key_line = num + 1
        # The customManager regex allows whitespace between hint and key, and a
        # `# noforward` line after it; reading less than that would report a dep
        # the writer then refuses.
        while key_line < len(lines) and not lines[key_line].strip():
            key_line += 1
        if key_line < len(lines) and lines[key_line].strip() == "# noforward":
            key_line += 1
        if key_line >= len(lines):
            continue
        kv = _ENV_KV.match(lines[key_line])
        if kv is not None:
            out.append(_site(key_line, kv.start(2), kv.group(2)))
    return out


FINDERS = {
    "github-actions": find_actions,
    "pub": find_pub,
    "pip_requirements": find_requirements,
    "pip-compile": find_requirements,
    "pep621": find_pep621,
    "pre-commit": find_precommit,
    "cargo": find_cargo,
    "npm": find_npm,
    "regex": find_annotated_env,
    "custom.regex": find_annotated_env,
}


def sites(manager, lines, dep, dep_type=""):
    """Every declaration of `dep` in these lines, or None when this manager has
    no exact locator. None is NOT "nothing to do": the caller refuses, because
    guessing at an unknown syntax is what this module exists to stop.

    Lines arrive from a CRLF-safe read, so the trailing CR is stripped for the
    parse only -- it sits after every span, so the spans stay valid."""
    finder = FINDERS.get(manager)
    if finder is None:
        return None
    return finder([line.rstrip("\r") for line in lines], dep, dep_type)


def _numbers(found):
    return ",".join(str(site.line + 1) for site in found)


def _values(found):
    return ", ".join("%d:%s" % (site.line + 1, site.value or "(no value)")
                     for site in found)


def resolve(manager, lines, dep, old, new, count):
    """The verdict for ONE group of report rows -- `count` updates of `dep` in
    this file, all from `old` to `new`.

      EDIT   the sites to rewrite; every one carries `old` already
      DONE   nothing to write, the declaration is at `new` (structural
             idempotence: re-reading the file is the whole check)
      REFUSE with the reason, printed rather than worked around

    The count rule is the one that replaces proximity. A report row describes
    ONE pin; if the file declares the dep at more lines than the report has rows
    for it, which line the row means is not knowable, so nothing is written. And
    when the counts DO agree the rewrite is the same under every assignment of
    rows to lines, because every site in the group carries the same old value
    and receives the same new one -- so there is nothing left to guess."""
    found = sites(manager, lines, dep)
    if found is None:
        return "REFUSE", [], (
            "no exact locator for manager '%s'; this tool refuses to edit a "
            "syntax it cannot parse" % manager)
    if not found:
        return "REFUSE", [], (
            "no %s declaration of '%s' in this file" % (manager, dep))
    # A located line carrying NO value spells the declaration in a form this
    # module cannot read. Falling through would let the other sites decide, and
    # a pubspec declaring `http` as a `hosted:` map then had its
    # dependency_overrides entry rewritten instead -- the report's dep, the
    # wrong declaration of it.
    if any(not site.value for site in found):
        return "REFUSE", [], (
            "'%s' is declared at line(s) %s, and a line carrying no value "
            "spells it in a form this locator cannot read -- writing some "
            "OTHER line instead is exactly what it refuses to do"
            % (dep, _values(found)))
    at_old = [site for site in found if site.value == old]
    at_new = [site for site in found if site.value == new]
    if at_old and len(at_old) == count:
        return "EDIT", at_old, ""
    if at_old:
        return "REFUSE", [], (
            "the report carries %d update(s) of '%s' here but the file declares "
            "it at %d line(s) holding %s (line %s) -- which one the report means "
            "is not knowable" % (count, dep, len(at_old), old, _numbers(at_old)))
    if at_new and len(at_new) == len(found):
        return "DONE", at_new, "already at %s" % new
    return "REFUSE", [], (
        "'%s' is declared at line(s) %s, and none of them carries the reported "
        "current value %s -- something moved, so nothing is written"
        % (dep, _values(found), old))
