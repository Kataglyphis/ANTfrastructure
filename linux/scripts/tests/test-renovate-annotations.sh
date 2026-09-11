#!/usr/bin/env bash
# Every `# renovate:` line in versions.env is actually MATCHED by the
# customManager regex in .github/renovate.json -- which is NOT the same check as
# "the annotation exists". One the regex misses is the same invisibility the
# annotation was written to end, and it is silent in exactly the same way.
# It runs over the SHIPPED files, not a fixture: the property has to hold for
# this repo's own config, and a fixture would prove it about a copy.
# docs/dependency-updates.md#the-source-of-truth-has-to-be-visible-too
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
HUB="$(cd "${TESTS_DIR}/../../.." && pwd)"
PY="${PREFLIGHT_PYTHON:-python3}"

ENV_FILE="${HUB}/linux/scripts/01-core/versions.env"
CFG_FILE="${HUB}/.github/renovate.json"

# <mode> -> the count, or the matched depName=key rows. Python because the
# pattern is a JavaScript regex living inside JSON, and re-typing it here would
# make this a test of the copy.
_probe() {
  "${PY}" - "${CFG_FILE}" "${ENV_FILE}" "$1" <<'PY'
import json
import re
import sys

cfg = json.load(open(sys.argv[1], encoding="utf-8"))
body = open(sys.argv[2], encoding="utf-8").read()
pats = [m for cm in cfg.get("customManagers", []) for m in cm["matchStrings"]]
# Python spells a named group (?P<x>...); JavaScript (?<x>...). The rest of the
# syntax these patterns use is common to both, so the translation is this one
# substitution and nothing else is rewritten.
found = []
for pat in pats:
    for m in re.finditer(pat.replace("(?<", "(?P<"), body):
        found.append("%s=%s" % (m.group("depName"), m.group("currentValue")))
written = len(re.findall(r"^# renovate: ", body, re.M))
if sys.argv[3] == "count":
    print("%d %d" % (written, len(found)))
else:
    print("\n".join(found))
PY
}

COUNTS="$(_probe count)"
ROWS="$(_probe rows)"

t_case "every annotation written in versions.env is matched by the regex"
t_assert_eq "${COUNTS% *}" "${COUNTS#* }" \
  "annotations written vs annotations the customManager regex matches"
t_assert_fails test "${COUNTS% *}" = "0"

t_case "the SOURCE OF TRUTH keys whose consumers Renovate already sees are visible"
# Each of these is a key a consumer repeats in a file one of Renovate's OWN
# managers reads -- OrchestrANT's pyproject.toml for all five. Renovate reported
# the copy and not the key until 2026-09-10.
for _want in ruff microsoft/onnxruntime microsoft/onnxruntime-genai \
             pytorch/pytorch pytorch/vision; do
  t_assert_contains "${ROWS}" "${_want}=" "${_want} must be visible to Renovate"
done

t_case "and the value the regex reads is the value the key carries"
t_assert_contains "${ROWS}" "ruff=$(sed -n 's/^RUFF_VERSION=//p' "${ENV_FILE}")" \
  "a regex that matches but reads the wrong value is worse than no match"

t_summary
