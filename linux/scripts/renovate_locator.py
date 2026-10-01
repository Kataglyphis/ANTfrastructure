#!/usr/bin/env python3
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
"""Where a dependency is declared, found by parsing each manager's syntax, never by text search.

See docs/dependency-updates.md#how-one-value-gets-rewritten
"""
import collections
import fnmatch
import json
import os
import re

# start/end: the value's half-open span, so a rewrite touches nothing else on the line.
Site = collections.namedtuple("Site", "line start end value")
# col: where the key starts, which decides nesting.
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
    """A PEP 503 project name, so a report's foo-bar finds the line spelling Foo_Bar."""
    return re.sub(r"[-_.]+", "-", name.strip()).lower()


def pep508_span(text):
    """(name, extras, start, end) of one PEP 508 requirement, the span excluding the marker; or None."""
    match = _PEP508_NAME.match(text)
    if not match:
        return None
    spec = text[match.end():].split(";", 1)[0]
    lead = len(spec) - len(spec.lstrip())
    start = match.end() + lead
    return match.group(1), match.group(2) or "", start, start + len(spec.strip())


def uncomment(line, quotes=""):
    """`line` cut at the first unquoted `#` after whitespace, since `@v1#frag` is no comment."""
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
    """The Key on a `key: value` line, or None; start indexes into `line`."""
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


# One YAML walk, three managers
def _open_node(nodes, stack, name, col):
    """Push a new mapping at `col`, closing everything it dedents out of."""
    while len(stack) > 1 and stack[-1]["col"] >= col:
        stack.pop()
    node = {"name": name, "col": col, "parent": stack[-1], "at": {}}
    nodes.append(node)
    stack.append(node)


def yaml_nodes(lines):
    """Every mapping the document opens, with its own keys as Sites; block scalars are skipped as text."""
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


# github-actions
def find_actions(lines, dep, _dep_type):
    """The ref of every step or job `uses:` naming this action, split at the last `@`."""
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


# pub (pubspec.yaml)
def find_pub(lines, dep, _dep_type):
    """The value of this dep's own key in a top-level pubspec section; a map-shaped dep comes back empty."""
    out = []
    for node in yaml_nodes(lines):
        if node["name"] not in PUB_SECTIONS or not _named(node, ""):
            continue
        site = node["at"].get(dep)
        if site is not None:
            out.append(site)
    return out


# pip_requirements
def _requirement_body(line):
    """One line without its comment or a trailing continuation `\\`, which is not part of the specifier."""
    body = uncomment(line)
    stripped = body.rstrip()
    return stripped[:-1] if stripped.endswith("\\") else body


def find_requirements(lines, dep, _dep_type):
    """The specifier of every PEP 508 line whose name normalises to this dep; options and comments skipped."""
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


# pep621 (pyproject.toml): only these arrays hold dependencies, so a `keywords` entry is never a pin.
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
    """`[` minus `]` outside quoted strings, so a bracket in a URL or marker cannot close the array."""
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
    """Specifiers of quoted PEP 508 strings naming this dep inside known dependency arrays."""
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


# pre-commit
def repo_name(url):
    """`owner/repo`, Renovate's depName for a pre-commit `repo:`; "" for local, meta and the like."""
    text = re.sub(r"\.git$", "", url.strip().strip("\"'"))
    text = re.sub(r"^[A-Za-z][A-Za-z0-9+.\-]*://", "", text)
    text = re.sub(r"^[^/]*@", "", text)
    parts = [p for p in text.replace(":", "/").split("/") if p]
    if len(parts) < 3:
        return ""
    return "/".join(parts[-2:]).casefold()


def find_precommit(lines, dep, _dep_type):
    """The `rev:` of the sequence item whose own `repo:` names this dep."""
    want = dep.casefold()
    return [node["at"]["rev"] for node in yaml_nodes(lines)
            if node["name"] == "-" and "rev" in node["at"]
            and "repo" in node["at"]
            and repo_name(node["at"]["repo"].value) == want]


# cargo
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
    """A cargo requirement narrowed to its version span; an inline table without `version` comes back empty."""
    text = site.value
    if len(text) >= 2 and text[0] in "\"'" and text[-1] == text[0]:
        return Site(site.line, site.start + 1, site.end - 1, text[1:-1])
    match = _INLINE_VERSION.search(text) if text.startswith("{") else None
    if match:
        return _site(site.line, site.start + match.start(1), match.group(1))
    return Site(site.line, site.start, site.end, "")


def _cargo_table(path):
    """(table, crate or None) when the whole path is a cargo dependency table, else None."""
    parts = list(path)
    if parts[:1] == ["workspace"]:
        parts = parts[1:]
    elif parts[:1] == ["target"] and len(parts) > 2:
        parts = parts[2:]
    if not parts or parts[0] not in CARGO_TABLES or len(parts) > 2:
        return None
    return parts[0], parts[1] if len(parts) == 2 else None


def find_cargo(lines, dep, _dep_type):
    """A key in a dependency table, or the `version` of `[dependencies.<dep>]`; a versionless entry is no site."""
    out = []
    path = []
    for num, line in enumerate(lines):
        # Uncomment first: a header followed by a comment is still a header.
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


# npm
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
    """Every string value as (key path, line, column, text); a scanner, since json.loads drops positions."""
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
    """The dep's value in a top-level dependencies object; only the full key path decides."""
    out = []
    for path, num, col, text in json_strings("\n".join(lines)):
        if len(path) == 2 and path[0] in NPM_OBJECTS and path[1] == dep:
            out.append(_site(num, col, text))
    return out


# custom.regex over an annotated env file: the KEY= line under a `# renovate: ... depName=` hint
_ENV_ANN = re.compile(r"^# renovate:.*?\bdepName=(\S+)(?:\s|$)")
_ENV_KV = re.compile(r"^([A-Z0-9_]+)=([^\s#]*)$")


def find_annotated_env(lines, dep, _dep_type):
    """The value of the KEY= line under each hint naming this dep; a hint without one is no site."""
    out = []
    for num, line in enumerate(lines):
        match = _ENV_ANN.match(line)
        if match is None or match.group(1) != dep:
            continue
        key_line = num + 1
        # Match the customManager regex: blank lines and a `# noforward` line may sit in between.
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


# custom.regex over CMake: not a Renovate manager name, so no report row can claim it by itself.
CMAKE = "regex:cmake"
_CMAKE_FILE = re.compile(r"(^|/)CMakeLists\.txt$|\.cmake$")
PRESET = os.path.join(os.path.dirname(os.path.abspath(__file__)), os.pardir, os.pardir,
                      "default.json")
_CMAKE_PATTERNS = []


def syntax(manager, path):
    """The syntax a report row's file is written in: the regex manager over a CMake file reads CMake."""
    if manager in ("regex", "custom.regex") and _CMAKE_FILE.search(path.replace("\\", "/")):
        return CMAKE
    return manager


def renovate_pattern(text):
    """A Renovate managerFilePatterns entry: /regex/ as written, anything else a glob."""
    if len(text) > 1 and text.startswith("/") and text.endswith("/"):
        return re.compile(text[1:-1])
    return re.compile(fnmatch.translate(text))


def cmake_patterns():
    """The preset's CMake matchStrings, compiled once; Python spells a named group (?P<x>...)."""
    if _CMAKE_PATTERNS:
        return _CMAKE_PATTERNS
    with open(PRESET, encoding="utf-8") as fh:
        managers = json.load(fh).get("customManagers") or []
    for manager in managers:
        if not any(renovate_pattern(p).search("CMakeLists.txt")
                   for p in manager.get("managerFilePatterns") or []):
            continue
        for text in manager.get("matchStrings") or []:
            rx = re.compile(re.sub(r"\(\?<(?=[A-Za-z_])", "(?P<", text), re.ASCII)
            if {"depName", "currentValue"} <= set(rx.groupindex):
                _CMAKE_PATTERNS.append(rx)
    return _CMAKE_PATTERNS


def find_cmake(lines, dep, _dep_type):
    """Every value a preset CMake matchString captures for this depName: the locator places what Renovate read."""
    text = "\n".join(lines)
    out = []
    for rx in cmake_patterns():
        for match in rx.finditer(text):
            if match.group("depName") != dep:
                continue
            start = match.start("currentValue")
            col = start - (text.rfind("\n", 0, start) + 1)
            out.append(_site(text.count("\n", 0, start), col, match.group("currentValue")))
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
    CMAKE: find_cmake,
}


def sites(manager, lines, dep, dep_type=""):
    """Every declaration of `dep`, or None (the caller refuses) when the manager has no exact locator."""
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
    """(EDIT|DONE|REFUSE, sites, reason) for `count` updates of `dep` from `old` to `new`.

    More declarations at `old` than report rows refuse: which line a row means is not knowable.
    """
    found = sites(manager, lines, dep)
    if found is None:
        return "REFUSE", [], (
            "no exact locator for manager '%s'; this tool refuses to edit a "
            "syntax it cannot parse" % manager)
    if not found:
        return "REFUSE", [], (
            "no %s declaration of '%s' in this file" % (manager, dep))
    # A valueless site is an unreadable form; letting the other sites decide rewrites the wrong one.
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
