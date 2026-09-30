#!/usr/bin/env python3
"""Fail on NEW dead shell functions, named nowhere once comments and definition heads are removed (dead-functions.allow).

docs/code-quality-tooling.md#dead-shell-functions-dead-functions
"""
import argparse
import os
import re
import subprocess
import sys
from collections import Counter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from quality_allow import check_keys, load_keys  # noqa: E402

import gate_scope  # noqa: E402
from verify_code_size import DEF_HEAD, ROOT, scan, shell_functions  # noqa: E402

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


def _rel(path):
    """Posix-spelled relpath, since allowlist and corpus keys never carry Windows backslashes."""
    return os.path.relpath(path, GRADED).replace(os.sep, "/")


def _kept(path):
    return _rel(path) not in SKIP_RELS


def _code(text):
    return HEAD.sub("", COMMENT.sub("", text))


def _tracked(root):
    """Every tracked path outside the excluded tops; ls-files keeps submodules and build output out."""
    out = subprocess.run(["git", "-C", root, "ls-files", "-z"],
                         capture_output=True, text=True)
    if out.returncode != 0:
        sys.stderr.write("ERROR: %s is not a git checkout; --root must be one\n" % root)
        raise SystemExit(2)
    for rel in sorted(p for p in out.stdout.split("\0") if p):
        head = rel.split("/", 1)[0]
        if head in EXCLUDE and rel != head:
            continue
        yield rel


def _size(path):
    try:
        return os.path.getsize(path)
    except OSError:
        return 0


def _outside(rel):
    """Is this path under SKIP_DIRS or SKIP_RELS, which the hub's own walk also skips?"""
    return (bool(set(rel.split("/")[:-1]) & SKIP_DIRS)
            or any(rel == skip or rel.startswith(skip + "/") for skip in SKIP_RELS))


def _corpus_rel(rel):
    """Is this path corpus text: not a doc, patch or allow file, and not skipped?"""
    return not rel.endswith(SKIP_SUFFIXES) and not _outside(rel)


def oversized():
    """Corpus files CORPUS_BYTES kept out, reported because the verdict did not read them."""
    return sorted(rel for rel in _tracked(GRADED)
                  if _corpus_rel(rel) and _size(os.path.join(GRADED, rel)) > CORPUS_BYTES)


def def_files(root):
    """(path, relpath) per graded shell file, never narrowed by size: an unseen definition is dead code let in."""
    if root == HUB:
        return scan(".sh")
    return ((os.path.join(root, rel), rel)
            for rel in _tracked(root) if rel.endswith(".sh"))


def _walk_corpus():
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


def _tracked_corpus():
    """Any other root's corpus: every tracked file small enough to be a call site."""
    for rel in _tracked(GRADED):
        path = os.path.join(GRADED, rel)
        if _corpus_rel(rel) and _size(path) <= CORPUS_BYTES:
            yield path, rel


def corpus():
    """(path, relpath) for every file whose text may NAME a function."""
    return _walk_corpus() if GRADED == HUB else _tracked_corpus()


def texts():
    """relpath -> text for every corpus file that reads as UTF-8."""
    out = {}
    for path, rel in corpus():
        try:
            with open(path, encoding="utf-8") as fh:
                out[rel] = fh.read()
        except (OSError, UnicodeDecodeError):
            continue
    return out


def self_mentions():
    """Name -> times its own bodies name it, since recursion or printing its name is not a call."""
    own = Counter()
    for path, rel in def_files(GRADED):
        for _rel, name, _start, body in shell_functions(path, rel):
            own[name] += len(re.findall(r"\b%s\b" % re.escape(name),
                                        _code("\n".join(body))))
    return own


def mentions(corpus_texts):
    """Identifier -> occurrences, comments, definition heads and self-mentions removed."""
    seen = Counter()
    for text in corpus_texts.values():
        seen.update(WORD.findall(_code(text)))
    seen.subtract(self_mentions())
    return seen


def definitions():
    """(file, name) for every shell function defined in the graded tree."""
    return sorted({(rel, name)
                   for path, rel in def_files(GRADED)
                   for _rel, name, _start, _body in shell_functions(path, rel)})


def dead(seen):
    """(all (file, name) shell definitions, the subset nothing else names)."""
    defined = definitions()
    return defined, [(rel, name) for rel, name in defined if not seen[name]]


def _definers():
    """Function name -> the set of files defining it."""
    out = {}
    for rel, name in definitions():
        out.setdefault(name, set()).add(rel)
    return out


def _names_of(corpus_texts):
    return {rel: set(WORD.findall(_code(text))) for rel, text in corpus_texts.items()}


def unlinked(corpus_texts):
    """Masked definitions provably uncalled; see docs/code-quality-tooling.md § The unlinked-definer arm."""
    definers = _definers()
    names = _names_of(corpus_texts)
    readers = {}

    def reads(rel):
        if rel not in readers:
            base = os.path.basename(rel)
            readers[rel] = {rel} | {o for o, text in corpus_texts.items() if base in text}
        return readers[rel]

    rows = []
    for rel, name in definitions():
        peers = definers[name] - {rel}
        text = corpus_texts.get(rel)
        if not peers or text is None or re.search(r"\b%s\b" % name, _code(text)):
            continue
        if any(o != rel and name in words and o not in definers[name]
               for o, words in names.items()):
            continue
        if any(reads(rel) & reads(peer) for peer in peers):
            continue
        rows.append((rel, name))
    return rows


def _isolated(rel, corpus_texts):
    if SOURCED.search(corpus_texts.get(rel, "")):
        return False
    base = os.path.basename(rel)
    return not any(base in text for other, text in corpus_texts.items() if other != rel)


def census(corpus_texts):
    """(isolated rows, same-name shared rows, considered count, unlinked count) over self-unnamed definitions."""
    considered = []
    for rel, name in definitions():
        text = corpus_texts.get(rel)
        if text is None or re.search(r"\b%s\b" % name, _code(text)):
            continue
        considered.append((rel, name))
    definers = Counter(name for _, name in definitions())
    return ([key for key in considered if _isolated(key[0], corpus_texts)],
            [key for key in considered if definers[key[1]] > 1],
            len(considered), len(unlinked(corpus_texts)))


def _where(allow_path=None):
    """Under a foreign root, name the tree, the freeze file and what the corpus skipped; silent for the hub."""
    if GRADED == HUB:
        return
    print("  root: %s" % GRADED)
    if allow_path:
        print("  allow: %s" % allow_path)
    big = oversized()
    if big:
        print("  %d tracked file(s) over %d KiB not read as corpus text -- an asset is "
              "not a call site (e.g. %s)"
              % (len(big), CORPUS_BYTES >> 10, ", ".join(big[:3])))


def report_census(rows, shared, considered, unlinked_count):
    print("=== dead function census (advisory, not a gate) ===")
    _where()
    print("  %d definition(s) their own file never names again; %d of those in a file "
          "that sources nothing and that nothing else names; %d share their name with "
          "another file's definition, %d of them unlinked from every other definer "
          "and failed by the gate"
          % (considered, len(rows), len(shared), unlinked_count))
    for rel, name in rows:
        print("  %s\t%s" % (rel, name))
    if not rows:
        print("  none -- every candidate sits in a sourced or externally named file")
    print("  masked (%d) -- the gate's live verdict for these comes from a same-named "
          "definition in another file, not from a call it can see:" % len(shared))
    for rel, name in shared:
        print("  %s\t%s" % (rel, name))
    if not shared:
        print("  none -- every candidate owns its name in the corpus")
    return 0


def _stale_note(key, corpus_texts):
    hit = disarmer(key, corpus_texts)
    if not hit:
        return ""
    return ("  [unlinked arm DISARMED by %s, which now names both %s and %s -- the "
            "function is not called again]" % (hit[0], os.path.basename(key.split("\t")[0]),
                                               os.path.basename(hit[1])))


def disarmer(key, corpus_texts):
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


def main(argv):
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
    if args.census:
        return report_census(*census(corpus_texts))
    defined, found = dead(mentions(corpus_texts))
    scoped = {"%s\t%s" % k for k in unlinked(corpus_texts)}
    allow = load_keys(allow_path)
    print("=== dead function gate ===")
    _where(allow_path)
    print("  %d shell functions; %d named nowhere else, %d more unlinked from every "
          "other definer of their name; %d frozen in %s"
          % (len(defined), len(found), len(scoped - {"%s\t%s" % k for k in found}),
             len(allow), os.path.basename(allow_path)))
    rc = check_keys({"%s\t%s" % k for k in found} | scoped, allow,
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
