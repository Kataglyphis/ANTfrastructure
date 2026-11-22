#!/usr/bin/env bash
# shared/contracts' OpenAI stream lines and whole answers: each case has its input and one outcome; the bindings prove the readers.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTRACTS="${TESTS_DIR}/../../../shared/contracts"
"${PREFLIGHT_PYTHON:-python3}" -I - "${1:-${CONTRACTS}/openai-stream-lines.json}" "${2:-${CONTRACTS}/openai-chat-answers.json}" <<'PY'
import json
import sys


def load(path):
    with open(path, encoding="utf-8") as fh:
        doc = json.load(fh)
    assert doc["schema_version"] == 1, f"{path}: schema_version must be 1"
    names = [case["name"] for case in doc["cases"]]
    assert len(set(names)) == len(names), f"{path}: two cases share a name"
    return doc["cases"]


def outcome(name, expect, keys):
    if "error" in expect:
        assert set(expect) == {"error"} and isinstance(expect["error"], str) and expect["error"], (
            f"{name}: an error case names only its message"
        )
        return
    assert set(expect) == keys, f"{name}: {sorted(expect)}"
    finish = expect["finish"]
    # Owner D8 (CON288): the raw finish_reason, so only an empty one is malformed.
    assert finish is None or (isinstance(finish, str) and finish), f"{name}: finish is the raw reason or null"
    usage = expect["usage"]
    assert usage is None or (len(usage) == 2 and all(type(n) is int and n >= 0 for n in usage)), (
        f"{name}: usage is two whole, non-negative counts or null"
    )


stream = load(sys.argv[1])
for case in stream:
    name = case["name"]
    assert case["lines"] and all(isinstance(line, str) for line in case["lines"]), f"{name}: lines are strings"
    outcome(name, case["expect"], {"text", "thinking", "finish", "usage", "done"})
    assert "error" in case["expect"] or isinstance(case["expect"]["done"], bool), f"{name}: done is a bool"
answers = load(sys.argv[2])
for case in answers:
    assert isinstance(case["body"], str) and case["body"], f"{case['name']}: the body is the answer's text"
    outcome(case["name"], case["expect"], {"text", "thinking", "finish", "usage"})
print(f"openai contracts: {len(stream)} stream cases and {len(answers)} whole answers, each with one outcome")
PY
