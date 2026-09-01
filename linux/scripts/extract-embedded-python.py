#!/usr/bin/env python3
"""Write each directly-executed Python heredoc to <outdir> so ruff can see it.

Only heredocs an interpreter runs are self-contained. Blocks that are `cat`ed
are FRAGMENTS assembled into one program later (see _smoke_genai_py_verdict in
06-packaging/smoke-common.sh) and are not valid Python alone.
See docs/code-quality-tooling.md.
"""
import os
import re
import sys

BLOCK = re.compile(
    # the opener line may carry trailing redirections (`<<'PY' 2>/dev/null || ...`)
    r"([^\n]*)<<-?'([A-Z_]*(?:PY|PYEOF|PYTHON)[A-Z_]*)'[^\n]*\n(.*?)\n[ \t]*\2[ \t]*$",
    re.S | re.M)
# `python3 - <<'PY'`, `"${py}" - <<'PY'`, `${PREFLIGHT_PYTHON} - <<'PY'`
RUNS_IT = re.compile(r"(python3?|\$\{?py\}?|PREFLIGHT_PYTHON)[^|]*(-|\s)$|python3? -")


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
        for m in BLOCK.finditer(text):
            if not RUNS_IT.search(m.group(1)):
                continue
            line = text[:m.start()].count("\n") + 1
            base = os.path.basename(src)[:-3] if src.endswith(".sh") else os.path.basename(src)
            out = os.path.join(outdir, "{}__{}.py".format(base, line))
            with open(out, "w", encoding="utf-8") as fh:
                fh.write(m.group(3) + "\n")
            print("{}\t{}:{}".format(out, src, line))
            written += 1
    if not written:
        sys.stderr.write("extract-embedded-python: no directly-executed heredocs found\n")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
