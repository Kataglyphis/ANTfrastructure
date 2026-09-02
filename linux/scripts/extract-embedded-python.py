#!/usr/bin/env python3
"""Write embedded Python to <outdir> so ruff can see it.

Two shapes:

* a heredoc an interpreter RUNS is self-contained and is emitted on its own;
* blocks that are `cat`ed are FRAGMENTS assembled into one program later (the
  `_smoke_genai_py_*` emitters in `06-packaging/smoke-common.sh` are 217 such
  lines). Individually they are invalid Python, so they used to be dropped and
  ruff never saw them. They are now concatenated per marker family, in file
  order, and emitted only when the result actually parses — which keeps
  non-Python heredocs out without guessing.

See docs/code-quality-tooling.md.
"""
import ast
import os
import re
import sys

BLOCK = re.compile(
    # The opener may carry trailing redirections (`<<'PY' 2>/dev/null || ...`).
    # DIGITS belong in the marker class: without them GENAI_PY_T1..T4 were missed
    # silently, so four of that program's six fragments never reached ruff.
    r"([^\n]*)<<-?'([A-Z_0-9]*(?:PY|PYEOF|PYTHON)[A-Z_0-9]*)'[^\n]*\n(.*?)\n[ \t]*\2[ \t]*$",
    re.S | re.M)
# `python3 - <<'PY'`, `"${PY}" - <<'PY'`, `${PREFLIGHT_PYTHON} - <<'PY'`, …
# The interpreter is often a VARIABLE, and its name varies in case and spelling.
# The old pattern hard-coded lowercase `${py}` and `PREFLIGHT_PYTHON`, so
# `"${PY}" -` did not match and the ~330-line program inside
# assert_pinned_versions -- the largest embedded Python in the tree -- was never
# linted, silently (found 2026-09-02).
RUNS_IT = re.compile(
    r"(python3?|\$\{?[A-Za-z_]*PY(?:THON)?[A-Za-z_0-9]*\}?)[^|]*(-|\s)$|python3? -",
    re.I)
CATS_IT = re.compile(r"\bcat\b")
# A comment cannot open a heredoc. Prose that QUOTES an opener is not one.
# docs/code-quality-tooling.md#comment-openers
COMMENT_OPENER = re.compile(r"[ \t]*#")
# Everything up to and including PY is the family, so two unrelated programs in
# one file (ONNX_PY vs GENAI_PY_*) are never spliced together.
FAMILY = re.compile(r"(PY(?:EOF|THON)?).*$")


def _stem(src):
    return os.path.basename(src)[:-3] if src.endswith(".sh") else os.path.basename(src)


def main():
    if len(sys.argv) < 3:
        sys.stderr.write("usage: extract-embedded-python.py <outdir> <file.sh>...\n")
        return 2
    outdir = sys.argv[1]
    os.makedirs(outdir, exist_ok=True)
    written = 0
    for src in sys.argv[2:]:
        try:
            with open(src, encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except OSError:
            continue
        # Test files carry deliberately-broken FIXTURE heredocs (that is what they
        # assert on), so assembling theirs would report their fixtures as real
        # findings. Directly-executed blocks above are unaffected.
        is_fixture_source = os.sep + "tests" + os.sep in os.path.abspath(src)
        fragments = {}
        for m in BLOCK.finditer(text):
            opener, marker, body = m.group(1), m.group(2), m.group(3)
            if COMMENT_OPENER.match(opener):
                continue
            if RUNS_IT.search(opener):
                line = text[:m.start()].count("\n") + 1
                out = os.path.join(outdir, "{}__{}.py".format(_stem(src), line))
                with open(out, "w", encoding="utf-8") as fh:
                    fh.write(body + "\n")
                print("{}\t{}:{}".format(out, src, line))
                written += 1
            elif CATS_IT.search(opener) and not is_fixture_source:
                fragments.setdefault(FAMILY.sub(r"\1", marker), []).append(body)
        for family, frags in sorted(fragments.items()):
            # A family of ONE is not "assembled" -- it is a lone fragment, and
            # linting one alone reports bogus undefined names (ast.parse catches
            # syntax errors, not F821). That is exactly what the old
            # never-extract-a-fragment rule protected against, so keep it.
            if len(frags) < 2:
                continue
            joined = "\n".join(frags) + "\n"
            try:
                ast.parse(joined)
            except SyntaxError:
                continue  # not one program after all — leave it out rather than guess
            out = os.path.join(outdir, "{}__{}.py".format(_stem(src), family.lower()))
            with open(out, "w", encoding="utf-8") as fh:
                fh.write(joined)
            print("{}\t{}: {} cat-ed fragments".format(out, src, len(frags)))
            written += 1
    if not written:
        sys.stderr.write("extract-embedded-python: nothing extracted\n")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
