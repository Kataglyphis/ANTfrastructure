#!/usr/bin/env python3
"""Catch functions whose STDOUT is their return value from logging on stdout.

WHY THIS EXISTS (2026-08-26 / 2026-08-27)
-----------------------------------------
`logging.sh` routes info() -- and therefore log() -- to fd 1, while warn()/err()
go to fd 2. A shell function whose result is consumed as `x="$(f)"` therefore
returns its log lines CONCATENATED WITH its value the moment anyone adds a log()
to it.

That is not hypothetical. It shipped twice:

  * compiler_cache_launcher() leaked an info() line into CC, so GCC was
    configured with CC="[INFO] Using sccache with SCCACHE_DIR=... (cap 30G)sccache
    gcc" and died as "configure: error: C compiler cannot create executables" --
    a message pointing nowhere near the cause.
  * normalize_llvm_cmake_dir() (tvm-detect.sh) logged on stdout while three call
    sites consumed its stdout as a path. Latent: it only fires when the LLVM
    CMake path actually needs normalising.

A unit test can pin one function. This pins the CLASS: any function that is both
called in a command substitution somewhere in the tree AND logs on fd 1 without
`>&2` is reported.

Exit 0 when clean, 1 when something is found.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "linux" / "scripts"
# log()/info() reach fd 1; warn()/err()/die() reach fd 2 and are therefore safe.
STDOUT_LOGGERS = re.compile(r"^\s*(log|info)\s")
FUNC_DEF = re.compile(r"^([a-z_][a-z0-9_]*)\(\)\s*\{(.*?)^\}", re.S | re.M)
SUBST = re.compile(r"\$\(\s*([a-z_][a-z0-9_]*)\b")


def main() -> int:
    files = [p for p in SCRIPTS.rglob("*.sh") if "windows" not in str(p)]
    consumed: set[str] = set()
    for p in files:
        consumed |= set(SUBST.findall(p.read_text(errors="replace")))

    findings = []
    for p in files:
        for name, body in FUNC_DEF.findall(p.read_text(errors="replace")):
            if name not in consumed:
                continue
            for lineno, line in enumerate(body.splitlines(), 1):
                if STDOUT_LOGGERS.match(line) and ">&2" not in line:
                    findings.append((p.relative_to(ROOT), name, line.strip()[:88]))

    if not findings:
        print(f"stdout-return gate OK: {len(consumed)} substituted function name(s), "
              "no stdout logging inside any of them.")
        return 0

    print(f"{len(findings)} function(s) log on STDOUT while their stdout is a return value:")
    for path, name, line in findings:
        print(f"  {path}: {name}()")
        print(f"      {line}")
    print("\nlog()/info() write to fd 1 (logging.sh:77,82). Append `>&2`, or the")
    print("caller's `x=\"$(f)\"` captures the log line together with the value.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
