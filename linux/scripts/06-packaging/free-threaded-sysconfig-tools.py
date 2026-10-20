#!/usr/bin/env python3
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
"""fix|check PREFIX: every compiler tool the X.Yt tree's sysconfig names runs here. See docs/consumer-image-contract.md#the-free-threaded-python"""

import ast
import glob
import os
import re
import shutil
import sys

# What setuptools and meson read to compile, archive and link an extension.
TOOL_VARS = ("CC", "CXX", "AR", "LDSHARED", "LDCXXSHARED", "BLDSHARED", "LINKCC")


def say(msg):
    print(f"[ft-sysconfig] {msg}", flush=True)


def tree_files(prefix):
    data = sorted(glob.glob(os.path.join(prefix, "lib", "python3.*t", "_sysconfigdata_t_*.py")))
    if len(data) != 1:
        sys.exit(f"[ft-sysconfig] ERROR: {prefix} holds {len(data)} lib/python3.*t/_sysconfigdata_t_*.py, want 1")
    lib = os.path.dirname(data[0])
    # sysconfig reads the .py; the 3.14+ JSON twin and the config Makefile carry the same values for other readers.
    twins = glob.glob(os.path.join(lib, "_sysconfig_vars_t_*.json")) + glob.glob(os.path.join(lib, "config-*", "Makefile"))
    return data[0], sorted(twins)


def build_time_vars(path):
    with open(path, encoding="utf-8") as f:
        tree = ast.parse(f.read(), path)
    for node in tree.body:
        if isinstance(node, ast.Assign) and any(getattr(t, "id", "") == "build_time_vars" for t in node.targets):
            return ast.literal_eval(node.value)
    sys.exit(f"[ft-sysconfig] ERROR: {path} assigns no build_time_vars")


def runs(tool):
    if os.path.isabs(tool):
        return os.path.isfile(tool) and os.access(tool, os.X_OK)
    return shutil.which(tool) is not None


def missing(variables):
    out = []
    for var in TOOL_VARS:
        words = str(variables.get(var) or "").split()
        if words and not runs(words[0]):
            out.append((var, words[0]))
    return out


def check(prefix):
    data, _ = tree_files(prefix)
    bad = missing(build_time_vars(data))
    if bad:
        say("ERROR: " + data + " names tools this image lacks: " + " ".join(f"{v}={t}" for v, t in bad))
        return 1
    say(f"every compiler tool {os.path.basename(data)} names runs here")
    return 0


def fix(prefix):
    data, twins = tree_files(prefix)
    # A cross build records the toolchain stage's path; the target image carries the same name on PATH.
    swaps = {tool: os.path.basename(tool) for _, tool in missing(build_time_vars(data))
             if os.path.isabs(tool) and shutil.which(os.path.basename(tool))}
    for path in [data, *twins]:
        with open(path, encoding="utf-8") as f:
            text = f.read()
        new = text
        for old, name in swaps.items():
            # The lookahead keeps .../riscv64-linux-gnu-gcc from matching inside .../riscv64-linux-gnu-gcc-ar.
            new = re.sub(re.escape(old) + r"(?![\w.+-])", name, new)
        if new != text:
            with open(path, "w", encoding="utf-8") as f:
                f.write(new)
            say(f"{path}: " + ", ".join(f"{old} -> {name}" for old, name in swaps.items()))
    return check(prefix)


def main(argv):
    if len(argv) != 3 or argv[1] not in ("fix", "check"):
        print(__doc__, file=sys.stderr)
        return 2
    return fix(argv[2]) if argv[1] == "fix" else check(argv[2])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
