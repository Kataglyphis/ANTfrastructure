#!/usr/bin/env python3
"""Fail on NEW dead shell functions: defined under linux/scripts or linux/host-config
and named nowhere else once comments, definition heads and a definition's mentions of
itself are removed, plus the unlinked-definer arm that reaches inside same-name masking.
Dispatch the scanner cannot see is frozen two-way in dead-functions.allow.
docs/code-quality-tooling.md#dead-shell-functions-dead-functions
"""
import os
import re
import sys
from collections import Counter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from quality_allow import check_keys, load_keys  # noqa: E402
from verify_code_size import DEF_HEAD, ROOT, functions, scan, shell_functions  # noqa: E402

ALLOW = os.path.join(os.path.dirname(os.path.abspath(__file__)), "dead-functions.allow")
CORPUS = ("linux", ".github", "docs/scripts", "Makefile")
SKIP_DIRS = {".git", "__pycache__", "patches", "_build", ".venv", "node_modules",
             ".pytest_cache", ".dart_tool"}
SKIP_RELS = {"linux/webserver/dist", "docs/scripts/mutations.json"}
SKIP_SUFFIXES = (".md", ".patch", ".diff", ".allow")
COMMENT = re.compile(r"(?:^|(?<=\s))#.*$", re.MULTILINE)
HEAD = re.compile(r"^\s*" + DEF_HEAD, re.MULTILINE)
WORD = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
SOURCED = re.compile(r"(?:^|[^\w.])(?:\.|source|source_module\w*)\s+\S", re.MULTILINE)


def _kept(path):
    return os.path.relpath(path, ROOT) not in SKIP_RELS


def _code(text):
    return HEAD.sub("", COMMENT.sub("", text))


def corpus():
    for top in CORPUS:
        root = os.path.join(ROOT, top)
        if os.path.isfile(root):
            yield root
            continue
        for base, dirs, files in os.walk(root):
            dirs[:] = [d for d in dirs
                       if d not in SKIP_DIRS and _kept(os.path.join(base, d))]
            for fn in sorted(files):
                path = os.path.join(base, fn)
                if not fn.endswith(SKIP_SUFFIXES) and _kept(path):
                    yield path


def texts():
    """relpath -> text for every corpus file that reads as UTF-8."""
    out = {}
    for path in corpus():
        try:
            with open(path, encoding="utf-8") as fh:
                out[os.path.relpath(path, ROOT)] = fh.read()
        except (OSError, UnicodeDecodeError):
            continue
    return out


def self_mentions():
    """Name -> times its own definitions' bodies name it. A diagnostic that prints
    the function's name is not a caller, and neither is recursion."""
    own = Counter()
    for path, rel in scan(".sh"):
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
    return sorted({(rel, name) for rel, name, _ in functions() if rel.endswith(".sh")})


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


def report_census(rows, shared, considered, unlinked_count):
    print("=== dead function census (advisory, not a gate) ===")
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


def main(argv):
    corpus_texts = texts()
    if "--census" in argv:
        return report_census(*census(corpus_texts))
    defined, found = dead(mentions(corpus_texts))
    scoped = {"%s\t%s" % k for k in unlinked(corpus_texts)}
    allow = load_keys(ALLOW)
    print("=== dead function gate ===")
    print("  %d shell functions; %d named nowhere else, %d more unlinked from every "
          "other definer of their name; %d frozen in %s"
          % (len(defined), len(found), len(scoped - {"%s\t%s" % k for k in found}),
             len(allow), os.path.basename(ALLOW)))
    rc = check_keys({"%s\t%s" % k for k in found} | scoped, allow,
                    "NEW dead function(s) -- nothing outside a comment names them. Delete the\n"
                    "function, or freeze it in dead-functions.allow naming the dispatch site:",
                    "STALE entr(ies) -- the function is called again or gone, delete the line.\n"
                    "An unlinked-definer row also goes STALE when a corpus file starts naming\n"
                    "both definers' basenames; that disarms the arm, it does not revive the code:",
                    describe=lambda k: k.replace("\t", "  ")
                    + ("  [unlinked definer]" if k in scoped else ""))
    if rc == 0:
        print("OK: no new dead functions")
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
