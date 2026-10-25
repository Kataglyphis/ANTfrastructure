#!/usr/bin/env python3
"""Lets cmake-format 0.6.13 run on Python 3.15+: its lexer gets the 3.14 re.Scanner, which 3.15 refuses for capturing groups."""

import argparse
import importlib.util
import os
import pathlib
import sys

MARKER = "# hub: cmakelang-py315"

# Python 3.14's re.Scanner verbatim, minus the 3.15 group check, so the tokens stay byte-identical.
COMPAT = f'''

{MARKER}
class _Py314Scanner:
    def __init__(self, lexicon, flags=0):
        from re import RegexFlag, _compiler, _parser
        from re._constants import BRANCH, SUBPATTERN
        if isinstance(flags, RegexFlag):
            flags = flags.value
        self.lexicon = lexicon
        p = []
        s = _parser.State()
        s.flags = flags
        for phrase, action in lexicon:
            gid = s.opengroup()
            p.append(_parser.SubPattern(s, [(SUBPATTERN, (gid, 0, 0, _parser.parse(phrase, flags)))]))
            s.closegroup(gid, p[-1])
        p = _parser.SubPattern(s, [(BRANCH, (None, p))])
        self.scanner = _compiler.compile(p)

    def scan(self, string):
        result = []
        match = self.scanner.scanner(string).match
        i = 0
        while True:
            m = match()
            if not m:
                break
            j = m.end()
            if i == j:
                break
            action = self.lexicon[m.lastindex - 1][1]
            if callable(action):
                self.match = m
                action = action(self, m.group())
            if action is not None:
                result.append(action)
            i = j
        return result, string[i:]
'''


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--force", action="store_true", help="patch below 3.15 too (tests)")
    args = parser.parse_args()
    if sys.version_info < (3, 15) and not args.force:
        print(f"cmakelang-py315: Python {sys.version_info[0]}.{sys.version_info[1]} needs no patch")
        return 0
    spec = importlib.util.find_spec("cmakelang")
    if spec is None or not spec.submodule_search_locations:
        print("cmakelang-py315: no cmakelang in this environment")
        return 0
    lex = pathlib.Path(next(iter(spec.submodule_search_locations))) / "lex" / "__init__.py"
    text = lex.read_text(encoding="utf-8")
    if MARKER in text:
        print(f"cmakelang-py315: {lex} already patched")
        return 0
    if text.count("re.Scanner(") != 1:
        print(f"cmakelang-py315: {lex} does not hold exactly one re.Scanner( call; is cmake-format still 0.6.13?", file=sys.stderr)
        return 1
    # A new file, never an in-place write: uv hardlinks site-packages from its cache, which must stay the wheel's bytes.
    tmp = lex.with_name(lex.name + ".py315")
    tmp.write_text(text.replace("re.Scanner(", "_Py314Scanner(") + COMPAT, encoding="utf-8")
    os.replace(tmp, lex)
    print(f"cmakelang-py315: patched {lex}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
