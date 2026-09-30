#!/usr/bin/env bash
# An annotation the regex misses is silently invisible, so the shipped files are checked; see docs/dependency-updates.md#the-source-of-truth-has-to-be-visible-too
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
HUB="$(cd "${TESTS_DIR}/../../.." && pwd)"
PY="${PREFLIGHT_PYTHON:-python3}"

ENV_FILE="${HUB}/linux/scripts/01-core/versions.env"
CFG_FILE="${HUB}/.github/renovate.json"

# _probe <count|rows>: Python reads the JavaScript regex out of the JSON, since a re-typed copy tests the copy.
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
# Consumers repeat these keys in files Renovate's own managers read, so the key itself must be visible too.
for _want in ruff microsoft/onnxruntime microsoft/onnxruntime-genai \
             pytorch/pytorch pytorch/vision; do
  t_assert_contains "${ROWS}" "${_want}=" "${_want} must be visible to Renovate"
done

t_case "the 2026-09-11 datasource families are visible too"
for _want in node python flutter Kitware/CMake ARM-software/armnn \
             microsoft/vcpkg FFmpeg/FFmpeg cuda vulkan nuget.exe wix \
             nvidia-cudnn-cu13 tensorrt ROCm/TheRock \
             protocolbuffers/protobuf ubuntu; do
  t_assert_contains "${ROWS}" "${_want}=" "${_want} must be visible to Renovate"
done

t_case "a versioning= annotation has the versioningTemplate that reads it"
# The engine ignores the captured group without the template, so the two come together.
if grep -q "versioning=" "${ENV_FILE}"; then
  t_assert_contains "$(cat "${CFG_FILE}")" versioningTemplate \
    "the captured versioning group is IGNORED without versioningTemplate"
fi

t_case "and the value the regex reads is the value the key carries"
t_assert_contains "${ROWS}" "ruff=$(sed -n 's/^RUFF_VERSION=//p' "${ENV_FILE}")" \
  "a regex that matches but reads the wrong value is worse than no match"

t_summary
