#!/usr/bin/env python3
"""Fail on NEW dead shell functions: defined under linux/scripts or linux/host-config
and named nowhere else once comments, definition heads and a definition's mentions of
itself are removed, plus the unlinked-definer arm that reaches inside same-name masking.
Dispatch the scanner cannot see is frozen two-way in dead-functions.allow.
docs/code-quality-tooling.md#dead-shell-functions-dead-functions

GRADING A CONSUMER. `--root` and `--allow` are the same contract
docs/scripts/verify_mutations.py already documents, and for the same reason the lint
gates take one: a submodule checkout puts this script INSIDE the consumer, where a root
derived from __file__ resolves to ContainerHub and the gate grades the wrong tree while
reporting green over one nobody looked at.

This gate needs TWO scan sets, and the second one decides whether the verdict means
anything: a function is dead only when NOTHING in the corpus names it, so a corpus that
is too small does not under-report -- it INVENTS dead code out of live functions. Under
the hub's own root both sets are the historical ones (SCAN for the definitions, CORPUS
for the text that may name them), so the hub's own verdict cannot move by a line. Under
any other root both come from `git ls-files`: every tracked *.sh defines, and every
tracked file that is not a doc, a patch or an allow file may call. `git ls-files`, not a
walk, because a vendored submodule is a GITLINK -- so a consumer's corpus can neither
swallow this repo's own scripts nor lose a call site to a build directory nobody
remembered to exclude.

The one narrowing a foreign root adds is CORPUS_BYTES, and it is printed rather than
applied quietly: the largest file the hub's own corpus has ever read is 120 KB, while a
consumer tracks 90 MB ASCII meshes whose vertex lists would be tokenised word by word.
A call site does not live in one, but a skipped file is still a file this pass did not
read, so the run says how many and names some.
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
# Top-level directories that belong to somebody else, and the size above which a tracked
# file is an asset rather than a call site. Both are consulted only under a foreign
# root: the hub's own CORPUS names neither, and its largest member is 120 KB.
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
# The tree being graded, bound once by main() from --root before any scan runs. The
# reachability pass is a web of small functions -- mentions -> self_mentions, census ->
# unlinked -> _definers -> definitions -- that all read the same one tree and none of
# which chooses it, so the tree is stated once here instead of in eleven signatures.
GRADED = HUB


def _kept(path):
    return os.path.relpath(path, GRADED) not in SKIP_RELS


def _code(text):
    return HEAD.sub("", COMMENT.sub("", text))


def _tracked(root):
    """Every tracked path under `root`, outside the excluded top-level directories.

    `git ls-files`, not a walk: a vendored submodule is a GITLINK, so the scope
    cannot swallow another repo's files, and build output cannot get in.
    """
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
    """Is this tracked path inside a directory -- or is it a file -- the corpus never
    reads? The same SKIP_DIRS and SKIP_RELS the hub's own walk applies."""
    return (bool(set(rel.split("/")[:-1]) & SKIP_DIRS)
            or any(rel == skip or rel.startswith(skip + "/") for skip in SKIP_RELS))


def _corpus_rel(rel):
    """Is this tracked path corpus text at all: not a doc, a patch or an allow file,
    and not inside a skipped directory?"""
    return not rel.endswith(SKIP_SUFFIXES) and not _outside(rel)


def oversized():
    """The corpus text CORPUS_BYTES kept out. Reported, not dropped quietly: each one
    is a file the reachability pass did not read, and reachability is the verdict."""
    return sorted(rel for rel in _tracked(GRADED)
                  if _corpus_rel(rel) and _size(os.path.join(GRADED, rel)) > CORPUS_BYTES)


def def_files(root):
    """(path, relpath) for every shell file whose definitions this gate grades: the
    hub's own SCAN walk under the hub, every tracked *.sh under any other root. Never
    narrowed by size -- a definition that goes unseen is dead code the gate lets in."""
    if root == HUB:
        return scan(".sh")
    return ((os.path.join(root, rel), rel)
            for rel in _tracked(root) if rel.endswith(".sh"))


def _walk_corpus():
    """The hub's own corpus: the CORPUS trees, walked."""
    for top in CORPUS:
        root = os.path.join(GRADED, top)
        if os.path.isfile(root):
            yield root, os.path.relpath(root, GRADED)
            continue
        for base, dirs, files in os.walk(root):
            dirs[:] = [d for d in dirs
                       if d not in SKIP_DIRS and _kept(os.path.join(base, d))]
            for fn in sorted(files):
                path = os.path.join(base, fn)
                if not fn.endswith(SKIP_SUFFIXES) and _kept(path):
                    yield path, os.path.relpath(path, GRADED)


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
    """Name -> times its own definitions' bodies name it. A diagnostic that prints
    the function's name is not a caller, and neither is recursion."""
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
    """Same-name masking, reached where the corpus makes it provable: a definition its
    own file never names again, whose every other mention sits in a file that DEFINES
    the name too, and where no corpus file names two of those files' basenames -- so no
    mention can be about this copy. Findings, not a census; see the doc anchor."""
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
    """(rows, shared, considered, unlinked_count) -- definitions their own file never
    names again; rows keeps the ones in a file that sources nothing and that nothing
    else names, shared the ones whose name a second file also defines, and the count
    the gate's unlinked-definer arm carves out of shared."""
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
    """Under a foreign root, say which tree the verdict is about, which freeze file it
    read, and what the corpus did NOT read. Silent under the hub's own root, whose
    output must not move by a line."""
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
    """Which corpus file disarmed this unlinked-definer row, or None. The arm only
    holds while NO file names two definers' basenames; when one starts to, the row
    goes stale for a reason that has nothing to do with the function being called."""
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
    ap.add_argument("--root", default=ROOT,
                    help="the tree to grade (default: this repo)")
    ap.add_argument("--allow", default=None,
                    help="the freeze file (default: dead-functions.allow beside this "
                         "script for the hub, <root>/dead-functions.allow otherwise)")
    ap.add_argument("--census", action="store_true",
                    help="print the advisory per-file pass instead of the gate")
    args = ap.parse_args(argv)

    global GRADED
    try:
        # resolve_root, not abspath: `git rev-parse` succeeds in any
        # SUBDIRECTORY of a checkout, so grading one anchors every allowlist
        # key a level down without saying so.
        GRADED = gate_scope.resolve_root(args.root, ROOT)
    except gate_scope.ScopeError as exc:
        return gate_scope.die(exc)
    # A consumer's freeze belongs to the consumer: keeping it beside this script would
    # put every repo's ratchet inside the hub, where no consumer can see its own
    # ratchet in its own diff.
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
