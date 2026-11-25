#!/usr/bin/env bash
# Every case of shared/contracts/usable-cpus.json must match a reference rule, so no binding is asked for a count the rule does not give.
set -euo pipefail
HUB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
CASES="${1:-${HUB}/shared/contracts/usable-cpus.json}"
"${PREFLIGHT_PYTHON:-python3}" -I - "${CASES}" <<'PY'
import sys
from fractions import Fraction
from json import loads
from math import floor
from pathlib import Path


def usable(affinity, cpu_max):
    """max(1, floor(min(affinity, the smallest quota/period from the own cgroup to the root)))."""
    limit = Fraction(affinity)
    for text in cpu_max:
        if text is None:
            continue
        quota, period = text.split()
        if quota != "max":
            limit = min(limit, Fraction(int(quota), int(period)))
    return max(1, floor(limit))


contract = loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
names = [case["name"] for case in contract["cases"]]
assert contract["schema_version"] == 1, "version 1"
assert len(set(names)) == len(names), "every name once"
for case in contract["cases"]:
    name, affinity, cpu_max = case["name"], case["affinity"], case["cpu_max"]
    assert isinstance(affinity, int) and affinity >= 1, f"{name}: affinity is a count of at least 1"
    assert isinstance(cpu_max, list) and all(t is None or isinstance(t, str) for t in cpu_max), f"{name}: cpu_max holds texts or null"
    assert case["expect"].keys() == {"usable"}, f"{name}: {sorted(case['expect'])}"
    got = usable(affinity, cpu_max)
    assert got == case["expect"]["usable"], f"{name}: the reference rule gives {got}"
print(f"usable-cpus: {len(names)} cases, each replayed through the reference rule")
PY
