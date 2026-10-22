#!/usr/bin/env bash
# The runtime probes contain heredocs whose closing braces are not function boundaries.

t_runtime_function() {
  # Heredoc-aware: the probe text these functions emit contains `}` lines of its own.
  python3 - "$1" "$2" <<'EXTRACT'
import sys
from pathlib import Path
source = Path(sys.argv[1])
lines = (source.read_text() + (source.parent / "runtime-consumer-contract.sh").read_text()).splitlines(True)
name = sys.argv[2]
start = next(i for i, l in enumerate(lines) if l.startswith(name + "() {"))
i, here = start + 1, None
while i < len(lines):
    line = lines[i]
    if here is None:
        if "<<'" in line:
            here = line.split("<<'", 1)[1].split("'", 1)[0]
        elif line.rstrip() == "}":
            break
    elif line.rstrip() == here:
        here = None
    i += 1
sys.stdout.write("".join(lines[start:i + 1]))
EXTRACT
}
