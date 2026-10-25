#!/usr/bin/env python3
"""Fail on NEW dead shell functions, named nowhere once comments and definition heads are removed (dead-functions.allow).

docs/code-quality-tooling.md#dead-shell-functions-dead-functions
"""
import argparse
import os
import re
import runpy
import shlex
import subprocess
import sys
from collections import Counter
from collections.abc import Iterator, Mapping, Sequence

import gate_scope
from quality_allow import check_keys, load_keys
from verify_code_size import DEF_HEAD, ROOT, scan, shell_functions

HUB = os.path.abspath(ROOT)
ALLOW = os.path.join(os.path.dirname(os.path.abspath(__file__)), "dead-functions.allow")
CORPUS = ("linux", ".github", "docs/scripts", "Makefile")
# Foreign-root only: vendored tops, and the size above which a tracked file is an asset, not a call site.
EXCLUDE = ("third_party",)
CORPUS_BYTES = 1 << 20
SKIP_DIRS = {".git", "__pycache__", "patches", "_build", ".venv", "node_modules",
             ".pytest_cache", ".dart_tool"}
SKIP_RELS = {"linux/webserver/dist", "docs/scripts/mutations.json"}
SKIP_SUFFIXES = (".md", ".patch", ".diff", ".allow")
COMMENT = re.compile(r"(?:^|(?<=\s))#.*$", re.MULTILINE)
HEAD = re.compile(r"^\s*" + DEF_HEAD, re.MULTILINE)
WORD = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
SOURCED = re.compile(r"(?:^|[^\w.])(?:\.|source|source_module\w*)\s+\S", re.MULTILINE)
# The graded tree, bound once by main() so the many small reachability helpers need not pass it.
GRADED = HUB


def _rel(path: str | os.PathLike[str]) -> str:
    """Posix-spelled relpath, since allowlist and corpus keys never carry Windows backslashes."""
    return os.path.relpath(path, GRADED).replace(os.sep, "/")


def _kept(path: str | os.PathLike[str]) -> bool:
    return _rel(path) not in SKIP_RELS


def _code(text: str) -> str:
    return HEAD.sub("", COMMENT.sub("", text))


def _tracked(root: str) -> Iterator[str]:
    """Every tracked path outside the excluded tops; ls-files keeps submodules and build output out."""
    out = subprocess.run(["git", "-C", root, "ls-files", "-z"],
                         capture_output=True, text=True, check=False)
    if out.returncode != 0:
        sys.stderr.write(f"ERROR: {root} is not a git checkout; --root must be one\n")
        raise SystemExit(2)
    for rel in sorted(p for p in out.stdout.split("\0") if p):
        head = rel.split("/", 1)[0]
        if head in EXCLUDE and rel != head:
            continue
        yield rel


def _size(path: str | os.PathLike[str]) -> int:
    try:
        return os.path.getsize(path)
    except OSError:
        return 0


def _outside(rel: str) -> bool:
    """Is this path under SKIP_DIRS or SKIP_RELS, which the hub's own walk also skips?"""
    return (bool(set(rel.split("/")[:-1]) & SKIP_DIRS)
            or any(rel == skip or rel.startswith(skip + "/") for skip in SKIP_RELS))


def _corpus_rel(rel: str) -> bool:
    """Is this path corpus text: not a doc, patch or allow file, and not skipped?"""
    return not rel.endswith(SKIP_SUFFIXES) and not _outside(rel)


def oversized() -> list[str]:
    """Corpus files CORPUS_BYTES kept out, reported because the verdict did not read them."""
    return sorted(rel for rel in _tracked(GRADED)
                  if _corpus_rel(rel) and _size(os.path.join(GRADED, rel)) > CORPUS_BYTES)


def def_files(root: str) -> Iterator[tuple[str, str]]:
    """(path, relpath) per graded shell file, never narrowed by size: an unseen definition is dead code let in."""
    if root == HUB:
        return scan(".sh")
    return ((os.path.join(root, rel), rel)
            for rel in _tracked(root) if rel.endswith(".sh"))


def _walk_corpus() -> Iterator[tuple[str, str]]:
    """The hub's own corpus: the CORPUS trees, walked."""
    for top in CORPUS:
        root = os.path.join(GRADED, top)
        if os.path.isfile(root):
            yield root, _rel(root)
            continue
        for base, dirs, files in os.walk(root):
            dirs[:] = [d for d in dirs
                       if d not in SKIP_DIRS and _kept(os.path.join(base, d))]
            for fn in sorted(files):
                path = os.path.join(base, fn)
                if not fn.endswith(SKIP_SUFFIXES) and _kept(path):
                    yield path, _rel(path)


def _tracked_corpus() -> Iterator[tuple[str, str]]:
    """Any other root's corpus: every tracked file small enough to be a call site."""
    for rel in _tracked(GRADED):
        path = os.path.join(GRADED, rel)
        if _corpus_rel(rel) and _size(path) <= CORPUS_BYTES:
            yield path, rel


def corpus() -> Iterator[tuple[str, str]]:
    """(path, relpath) for every file whose text may NAME a function."""
    return _walk_corpus() if GRADED == HUB else _tracked_corpus()


def _shared_bootstrap_rel() -> str | None:
    """Return the declared consumer mirror path, including nondefault layouts."""
    if ".antfrastructure-shared.manifest" not in set(_tracked(GRADED)):
        return None
    manifest = os.path.join(GRADED, ".antfrastructure-shared.manifest")
    if not os.path.isfile(manifest):
        return None
    with open(manifest, encoding="utf-8") as fh:
        rows = [line.strip().split(maxsplit=1) for line in fh
                if line.strip() and not line.lstrip().startswith("#")]
    selected = [row for row in rows if row[0] == "antfrastructure-sh"]
    if not selected:
        return None
    if len(selected) != 1:
        raise ValueError("antfrastructure-sh must be declared once")
    if len(selected[0]) == 2:
        rel = selected[0][1]
    else:
        registry = os.path.join(HUB, "shared/config/shared-assets.manifest")
        with open(registry, encoding="utf-8") as fh:
            defaults = [fields[2].strip() for line in fh
                        if len(fields := line.split("|")) >= 3
                        and fields[0].strip() == "antfrastructure-sh"]
        if len(defaults) != 1:
            raise ValueError("shared asset registry lacks one antfrastructure-sh default path")
        rel = defaults[0]
    parts = rel.replace("\\", "/").split("/")
    if not rel or os.path.isabs(rel) or ":" in parts[0] or ".." in parts or "." in parts:
        raise ValueError("antfrastructure-sh mirror must be a rooted-relative path")
    return "/".join(parts)


def _command_calls(command: list[str], mirror: str, names: set[str]) -> set[str]:
    """Only shell command words after a source of the declared mirror are calls."""
    if len(command) != 3 or command[:2] != ["bash", "-lc"]:
        return set()
    lexer = shlex.shlex(command[2], posix=True, punctuation_chars=";&|")
    lexer.whitespace_split = True
    words = list(lexer)
    statements: list[list[str]] = [[]]
    for word in words:
        if word in {";", "&&", "||", "|"}:
            statements.append([])
        else:
            statements[-1].append(word)
    loaded = False
    called = set()
    for statement in statements:
        if len(statement) >= 2 and statement[0] in {"source", "."} and statement[1] == mirror:
            loaded = True
        elif loaded and statement and statement[0] in names:
            called.add(statement[0])
    return called


def shared_api_calls() -> set[tuple[str, str]]:
    """Calls in the validated image-consumer command to a declared shared shell mirror."""
    if GRADED == HUB:
        return set()
    try:
        mirror = _shared_bootstrap_rel()
        if mirror is None:
            return set()
        names = {name for rel, name in definitions() if rel == mirror}
        if not names:
            return set()
        plan_path = os.path.join(HUB, "shared/config/image-consumers.json")
        read_plan = runpy.run_path(os.path.join(HUB, "linux/scripts/image-acceptance.py"))["read_plan"]
        plan = read_plan(plan_path)
        return {(mirror, name) for row in plan["consumers"]
                for name in _command_calls(row["command"], mirror, names)}
    except (OSError, ValueError, KeyError, TypeError) as exc:
        sys.stderr.write(f"ERROR: cannot validate shared bootstrap call evidence: {exc}\n")
        raise SystemExit(2) from exc


def texts() -> dict[str, str]:
    """relpath -> text for every corpus file that reads as UTF-8."""
    out = {}
    for path, rel in corpus():
        try:
            with open(path, encoding="utf-8") as fh:
                out[rel] = fh.read()
        except (OSError, UnicodeDecodeError):
            continue
    return out


def self_mentions() -> Counter[str]:
    """Name -> times its own bodies name it, since recursion or printing its name is not a call."""
    own = Counter()
    for path, rel in def_files(GRADED):
        for _rel, name, _start, body in shell_functions(path, rel):
            own[name] += len(re.findall(rf"\b{re.escape(name)}\b",
                                        _code("\n".join(body))))
    return own


def mentions(corpus_texts: Mapping[str, str]) -> Counter[str]:
    """Identifier -> occurrences, comments, definition heads and self-mentions removed."""
    seen = Counter()
    for text in corpus_texts.values():
        seen.update(WORD.findall(_code(text)))
    seen.subtract(self_mentions())
    return seen


def definitions() -> list[tuple[str, str]]:
    """(file, name) for every shell function defined in the graded tree."""
    return sorted({(rel, name)
                   for path, rel in def_files(GRADED)
                   for _rel, name, _start, _body in shell_functions(path, rel)})


def dead(seen: Counter[str]) -> tuple[list[tuple[str, str]], list[tuple[str, str]]]:
    """(all (file, name) shell definitions, the subset nothing else names)."""
    defined = definitions()
    return defined, [(rel, name) for rel, name in defined if not seen[name]]


def _definers() -> dict[str, set[str]]:
    """Function name -> the set of files defining it."""
    out = {}
    for rel, name in definitions():
        out.setdefault(name, set()).add(rel)
    return out


def _names_of(corpus_texts: Mapping[str, str]) -> dict[str, set[str]]:
    return {rel: set(WORD.findall(_code(text))) for rel, text in corpus_texts.items()}


def unlinked(corpus_texts: Mapping[str, str]) -> list[tuple[str, str]]:
    """Masked definitions provably uncalled; see docs/code-quality-tooling.md § The unlinked-definer arm."""
    definers = _definers()
    names = _names_of(corpus_texts)
    readers = {}

    def reads(rel: str) -> set[str]:
        if rel not in readers:
            base = os.path.basename(rel)
            readers[rel] = {rel} | {o for o, text in corpus_texts.items() if base in text}
        return readers[rel]

    rows = []
    for rel, name in definitions():
        peers = definers[name] - {rel}
        text = corpus_texts.get(rel)
        if not peers or text is None or re.search(rf"\b{name}\b", _code(text)):
            continue
        if any(o != rel and name in words and o not in definers[name]
               for o, words in names.items()):
            continue
        if any(reads(rel) & reads(peer) for peer in peers):
            continue
        rows.append((rel, name))
    return rows


def _isolated(rel: str, corpus_texts: Mapping[str, str]) -> bool:
    if SOURCED.search(corpus_texts.get(rel, "")):
        return False
    base = os.path.basename(rel)
    return not any(base in text for other, text in corpus_texts.items() if other != rel)


def census(
    corpus_texts: Mapping[str, str],
    external_calls: set[tuple[str, str]] | None = None,
) -> tuple[list[tuple[str, str]], list[tuple[str, str]], int, int]:
    """(isolated rows, same-name shared rows, considered count, unlinked count) over self-unnamed definitions."""
    external_calls = external_calls or set()
    considered = []
    for rel, name in definitions():
        if (rel, name) in external_calls:
            continue
        text = corpus_texts.get(rel)
        if text is None or re.search(rf"\b{name}\b", _code(text)):
            continue
        considered.append((rel, name))
    definers = Counter(name for _, name in definitions())
    return ([key for key in considered if _isolated(key[0], corpus_texts)],
            [key for key in considered if definers[key[1]] > 1],
            len(considered), len([row for row in unlinked(corpus_texts) if row not in external_calls]))


def _where(allow_path: str | None = None) -> None:
    """Under a foreign root, name the tree, the freeze file and what the corpus skipped; silent for the hub."""
    if GRADED == HUB:
        return
    print(f"  root: {GRADED}")
    if allow_path:
        print(f"  allow: {allow_path}")
    big = oversized()
    if big:
        print(f"  {len(big)} tracked file(s) over {CORPUS_BYTES >> 10} KiB not read as corpus text -- an asset is "
              f"not a call site (e.g. {', '.join(big[:3])})")


def report_census(
    rows: list[tuple[str, str]],
    shared: list[tuple[str, str]],
    considered: int,
    unlinked_count: int,
) -> int:
    print("=== dead function census (advisory, not a gate) ===")
    _where()
    print(f"  {considered} definition(s) their own file never names again; {len(rows)} of those in a file "
          f"that sources nothing and that nothing else names; {len(shared)} share their name with "
          f"another file's definition, {unlinked_count} of them unlinked from every other definer "
          "and failed by the gate")
    for rel, name in rows:
        print(f"  {rel}\t{name}")
    if not rows:
        print("  none -- every candidate sits in a sourced or externally named file")
    print(f"  masked ({len(shared)}) -- the gate's live verdict for these comes from a same-named "
          "definition in another file, not from a call it can see:")
    for rel, name in shared:
        print(f"  {rel}\t{name}")
    if not shared:
        print("  none -- every candidate owns its name in the corpus")
    return 0


def _stale_note(key: str, corpus_texts: Mapping[str, str]) -> str:
    hit = disarmer(key, corpus_texts)
    if not hit:
        return ""
    rel, _, _ = key.partition("\t")
    return (f"  [unlinked arm DISARMED by {hit[0]}, which now names both "
            f"{os.path.basename(rel)} and {os.path.basename(hit[1])} -- "
            "the function is not called again]")


def disarmer(key: str, corpus_texts: Mapping[str, str]) -> tuple[str, str] | None:
    """The corpus file now naming two definers' basenames, which stales the row without a call, or None."""
    rel, _, name = key.partition("\t")
    peers = _definers().get(name, set()) - {rel}
    base = os.path.basename(rel)
    for peer in sorted(peers):
        pbase = os.path.basename(peer)
        for other in sorted(corpus_texts):
            text = corpus_texts[other]
            if base in text and pbase in text:
                return other, peer
    return None


def main(argv: Sequence[str]) -> int:
    ap = argparse.ArgumentParser(description="Fail on new dead shell functions.")
    ap.add_argument("--root", default=None,
                    help="the tree to grade (default: this repo)")
    ap.add_argument("--allow", default=None,
                    help="the freeze file (default: dead-functions.allow beside this "
                         "script for the hub, <root>/dead-functions.allow otherwise)")
    ap.add_argument("--census", action="store_true",
                    help="print the advisory per-file pass instead of the gate")
    args = ap.parse_args(argv)

    global GRADED
    try:
        # resolve_root, not abspath: a subdirectory root would silently shift every allowlist key.
        GRADED = gate_scope.resolve_root(args.root, ROOT)
    except gate_scope.ScopeError as exc:
        return gate_scope.die(exc)
    # A consumer's freeze lives in the consumer, where its own diff shows it.
    allow_path = args.allow or (ALLOW if GRADED == HUB
                                else os.path.join(GRADED, "dead-functions.allow"))
    corpus_texts = texts()
    external_calls = shared_api_calls()
    if args.census:
        return report_census(*census(corpus_texts, external_calls))
    defined, found = dead(mentions(corpus_texts))
    scoped = {f"{rel}\t{name}" for rel, name in unlinked(corpus_texts)
              if (rel, name) not in external_calls}
    found_keys = {f"{rel}\t{name}" for rel, name in found
                  if (rel, name) not in external_calls}
    allow = load_keys(allow_path)
    print("=== dead function gate ===")
    _where(allow_path)
    if external_calls:
        print(f"  {len(external_calls)} shared bootstrap function(s) used by executable image-consumer commands")
    print(f"  {len(defined)} shell functions; {len(found_keys)} named nowhere else, "
          f"{len(scoped - found_keys)} more unlinked from every "
          f"other definer of their name; {len(allow)} frozen in {os.path.basename(allow_path)}")
    rc = check_keys(found_keys | scoped, allow,
                    "NEW dead function(s) -- nothing outside a comment names them. Delete the\n"
                    "function, or freeze it in dead-functions.allow naming the dispatch site:",
                    "STALE entr(ies) -- the function is called again or gone, delete the line.\n"
                    "An unlinked-definer row also goes STALE when a corpus file starts naming\n"
                    "both definers' basenames; that disarms the arm, it does not revive the code:",
                    describe=lambda k: k.replace("\t", "  ")
                    + ("  [unlinked definer]" if k in scoped else ""),
                    describe_stale=lambda k: k.replace("\t", "  ") + _stale_note(k, corpus_texts))
    if rc == 0:
        print("OK: no new dead functions")
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
