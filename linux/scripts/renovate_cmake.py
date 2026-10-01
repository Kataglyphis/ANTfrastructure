#!/usr/bin/env python3
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
"""CMake read by its own grammar, for the audit; it never reuses the preset's regexes, which the locator runs.

See docs/dependency-updates.md#cmake-dependencies
"""
import bisect
import re

_IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
_BRACKET = re.compile(r"\[(=*)\[")
_ANNOTATION = re.compile(r"# renovate: datasource=\S+ depName=(\S+)(?:\s|$)")
_DOTTED = re.compile(r"[\w+-]+(?:\.[\w+-]+)+", re.ASCII)
_ARCHIVE = re.compile(r"https://github\.com/([\w.-]+/[\w.-]+)/archive/refs/tags/([\w.+-]+?)"
                      r"\.(?:zip|tar\.gz)", re.ASCII)
_BLANK = " \t\r\n"
_UNQUOTED_END = _BLANK + '()#"'


def _bracket_end(text, i):
    """The index past a bracket argument opening at i, or -1 when none opens there."""
    match = _BRACKET.match(text, i)
    if match is None:
        return -1
    close = text.find("]" + match.group(1) + "]", match.end())
    if close < 0:
        raise ValueError(f"a bracket [{match.group(1)}[ opening at offset {i} never closes")
    return close + len(match.group(1)) + 2


def _comment(text, i):
    """(end, text) of the comment at i: a bracket comment, or the rest of the line."""
    end = _bracket_end(text, i + 1)
    if end < 0:
        end = text.find("\n", i)
        end = len(text) if end < 0 else end
    return end, text[i:end]


def _quoted(text, i):
    """(end, content) of the quoted argument opening at i; a backslash escapes the next character."""
    j = i + 1
    while j < len(text):
        if text[j] == "\\":
            j += 2
        elif text[j] == '"':
            return j + 1, text[i + 1:j]
        else:
            j += 1
    raise ValueError(f"a quoted argument opening at offset {i} never closes")


def _unquoted(text, i):
    """(end, text) of the unquoted argument at i."""
    j = i
    while j < len(text) and text[j] not in _UNQUOTED_END:
        j += 2 if text[j] == "\\" else 1
    return j, text[i:j]


def _token(text, i, line):
    """(end, token) for one argument-list token at i that is not a paren."""
    if text[i] == "#":
        end, body = _comment(text, i)
        return end, {"comment": body, "line": line}
    if text[i] == '"':
        end, body = _quoted(text, i)
        return end, {"arg": body, "line": line, "quoted": True}
    end = _bracket_end(text, i)
    if end >= 0:
        return end, {"arg": text[i:end], "line": line, "quoted": True}
    end, body = _unquoted(text, i)
    return end, {"arg": body, "line": line, "quoted": False}


def _arguments(text, i, lines):
    """(end, tokens) of the argument list opening at i; nested parens stay tokens, as CMake keeps them."""
    depth, args = 0, []
    i += 1
    while i < len(text):
        char = text[i]
        if char in _BLANK:
            i += 1
        elif char == ")" and depth == 0:
            return i + 1, args
        elif char in "()":
            depth += 1 if char == "(" else -1
            args.append({"paren": char, "line": lines(i)})
            i += 1
        else:
            i, token = _token(text, i, lines(i))
            args.append(token)
    raise ValueError("an argument list never closes")


def _put(out, name, line, item):
    """Key a top-level item by what a reader looks for, `<command>@<line>`, unique even for two on one line."""
    key = f"{name}@{line}"
    n = 2
    while key in out:
        key = f"{name}@{line}#{n}"
        n += 1
    out[key] = item


def parse(text):
    """Every top-level command and comment, in file order; a file CMake would not read raises ValueError."""
    breaks = [m.start() for m in re.finditer("\n", text)]

    def lines(i):
        return bisect.bisect_left(breaks, i) + 1

    out, i = {}, 0
    while i < len(text):
        if text[i] in _BLANK:
            i += 1
            continue
        if text[i] == "#":
            end, body = _comment(text, i)
            _put(out, "#", lines(i), {"comment": body, "line": lines(i)})
            i = end
            continue
        ident = _IDENT.match(text, i)
        paren = text.find("(", ident.end()) if ident else -1
        if ident is None or paren < 0 or text[ident.end():paren].strip(" \t"):
            raise ValueError(f"line {lines(i)}: {text[i:i + 30]!r} is neither a command nor a comment")
        line = lines(i)
        i, args = _arguments(text, paren, lines)
        _put(out, ident.group(0), line, {"name": ident.group(0), "line": line, "args": args})
    return out


def _names(token, dep):
    match = _ANNOTATION.match(token.get("comment", ""))
    return match is not None and match.group(1) == dep


def _keyword(token, word):
    return token.get("arg") == word and not token.get("quoted")


def _at(args, j):
    return args[j] if 0 <= j < len(args) else {}


def _whole(key, j, token):
    return ((key, "args", j, "arg"), token["arg"], 0, len(token["arg"]), "")


def _annotated(key, args, j):
    """The value the annotation at args[j] points at on the very next line: `GIT_TAG <v>` or `"<v>"`."""
    nxt = _at(args, j + 1)
    if nxt.get("line") != args[j]["line"] + 1:
        return []
    if _keyword(nxt, "GIT_TAG") and "arg" in _at(args, j + 2):
        return [_whole(key, j + 2, args[j + 2])]
    if "arg" in nxt and nxt["quoted"]:
        return [_whole(key, j + 1, nxt)]
    return []


def _github(url, dep):
    return url in {host + dep + tail for host in ("https://github.com/", "git@github.com:")
                   for tail in ("", ".git")}


def _git(key, args, j, dep):
    """GIT_REPOSITORY <dep's URL> GIT_TAG <dotted tag>, with nothing between them; a branch or a SHA is no version."""
    url, tag, value = _at(args, j + 1), _at(args, j + 2), _at(args, j + 3)
    if not (_github(url.get("arg"), dep) and _keyword(tag, "GIT_TAG")):
        return []
    if not _DOTTED.fullmatch(value.get("arg") or ""):
        return []
    return [_whole(key, j + 3, value)]


def _hashed(args):
    """Why a tag archive checked by a hash is not moved, or ""."""
    for word in ("URL_HASH", "URL_MD5"):
        if any(_keyword(token, word) for token in args):
            return (f"this archive is checked against its {word}, which hashes the archive being "
                    "replaced. Nothing here downloads the new one to recompute it, so the tag "
                    "is not moved on its own -- move the URL and its hash together, by hand")
    return ""


def _archive(key, args, j, dep):
    """URL https://github.com/<dep>/archive/refs/tags/<tag>.zip|.tar.gz: the tag inside the URL."""
    url = _at(args, j + 1).get("arg") or ""
    match = _ARCHIVE.fullmatch(url)
    if match is None or match.group(1) != dep:
        return []
    return [((key, "args", j + 1, "arg"), url, match.start(2), match.end(2), _hashed(args))]


def _in_command(key, args, dep):
    out = []
    for j, token in enumerate(args):
        if _names(token, dep):
            out.extend(_annotated(key, args, j))
        elif _keyword(token, "GIT_REPOSITORY"):
            out.extend(_git(key, args, j, dep))
        elif _keyword(token, "URL"):
            out.extend(_archive(key, args, j, dep))
    return out


def _set_after(annotation, item):
    """`set(<NAME> <v>` on the line right below a top-level annotation: <v> is the second argument."""
    key, command = item
    args = command.get("args") or []
    if command.get("name", "").lower() != "set" or command["line"] != annotation["line"] + 1:
        return []
    if len(args) < 2 or "arg" not in args[0] or "arg" not in args[1]:
        return []
    return [_whole(key, 1, args[1])]


def declarations(struct, dep):
    """(path, leaf, start, end, why) for every place this file declares `dep` in a form the preset reads."""
    items = list(struct.items())
    out = []
    for k, (key, item) in enumerate(items):
        if "args" in item:
            out.extend(_in_command(key, item["args"], dep))
        elif _names(item, dep) and k + 1 < len(items):
            out.extend(_set_after(item, items[k + 1]))
    return out
