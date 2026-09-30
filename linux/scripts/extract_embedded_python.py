#!/usr/bin/env python3
"""Write embedded Python to <outdir> for ruff. See docs/code-quality-tooling.md#python-that-lives-in-shell-heredocs"""
import ast
import os
import re
import sys

BLOCK = re.compile(
    # Openers may carry redirections; digits in the marker class catch GENAI_PY_T1..T4.
    r"([^\n]*)<<-?'([A-Z_0-9]*(?:PY|PYEOF|PYTHON)[A-Z_0-9]*)'[^\n]*\n(.*?)\n[ \t]*\2[ \t]*$",
    re.S | re.M)
# The interpreter is often a variable whose name varies in case and spelling ("${PY}" -, ${PREFLIGHT_PYTHON} -).
RUNS_IT = re.compile(
    r"(python3?|\$\{?[A-Za-z_]*PY(?:THON)?[A-Za-z_0-9]*\}?)[^|]*(-|\s)$|python3? -",
    re.I)
CATS_IT = re.compile(r"\bcat\b")
# A comment cannot open a heredoc. docs/code-quality-tooling.md#comment-openers
COMMENT_OPENER = re.compile(r"[ \t]*#")
# The family ends at PY, so unrelated programs in one file (ONNX_PY, GENAI_PY_*) never splice.
FAMILY = re.compile(r"(PY(?:EOF|THON)?).*$")


def _stem(src):
    return os.path.basename(src)[:-3] if src.endswith(".sh") else os.path.basename(src)


def main():
    if len(sys.argv) < 3:
        sys.stderr.write("usage: extract_embedded_python.py <outdir> <file.sh>...\n")
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
        # Test fixtures are deliberately broken; assembling them would report fake findings.
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
            # A lone fragment lints with bogus undefined names, which ast.parse cannot catch.
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
