#!/usr/bin/env bash
# shared/contracts/openai-stream-lines.json's shape: each case has lines and one outcome; the readers are proven in OxidANT and OrchestrANT.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"${PREFLIGHT_PYTHON:-python3}" -I - "${1:-${TESTS_DIR}/../../../shared/contracts/openai-stream-lines.json}" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    doc = json.load(fh)
assert doc["schema_version"] == 1, "schema_version must be 1"
names = set()
for case in doc["cases"]:
    name = case["name"]
    assert name not in names, f"two cases named {name!r}"
    names.add(name)
    assert case["lines"] and all(isinstance(line, str) for line in case["lines"]), f"{name}: lines are strings"
    expect = case["expect"]
    if "error" in expect:
        assert set(expect) == {"error"} and expect["error"], f"{name}: an error case names only its message"
        continue
    assert set(expect) == {"text", "thinking", "finish", "usage", "done"}, f"{name}: {sorted(expect)}"
    assert expect["finish"] in (None, "stop", "length"), f"{name}: finish is stop, length or null"
    usage = expect["usage"]
    assert usage is None or (len(usage) == 2 and all(isinstance(n, int) for n in usage)), f"{name}: usage"
    assert isinstance(expect["done"], bool), f"{name}: done is a bool"
print(f"openai-stream-lines: {len(names)} cases, each with lines and one outcome")
PY
