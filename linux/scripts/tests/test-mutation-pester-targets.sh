#!/usr/bin/env bash
# The Linux mutation shards carry no Pester, so a recipe whose test is a Pester-style suite skips there and fails every run.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
MANIFEST="${TESTS_DIR}/../../../docs/scripts/mutations.json"
WINDOWS_TESTS="${TESTS_DIR}/../../../windows/scripts/tests"

# _pester_targets <manifest> <tests-dir>: prints "id -> suite" for each recipe that names a Pester-style suite; exit 1 if any.
_pester_targets() {
  python3 - "$1" "$2" <<'PY'
import json, pathlib, re, sys

manifest, tests = sys.argv[1], pathlib.Path(sys.argv[2])
# Invoke-Tests.ps1's own detection: Pester-only keywords, never Describe, which the harness also exports.
pester = re.compile(r"(?m)^\s*(BeforeAll|BeforeEach|AfterAll|AfterEach|Context)\s")
found = []
for entry in json.load(open(manifest, encoding="utf-8")):
    for names in re.findall(r"-Only\s+(\S+)", entry.get("test", "")):
        for name in names.split(","):
            suite = tests / name
            if suite.is_file() and pester.search(suite.read_text(encoding="utf-8")):
                found.append(f"{entry['id']} -> {name}")
print("\n".join(found))
sys.exit(1 if found else 0)
PY
}

_work="$(mktemp -d)"; trap 'rm -rf "${_work}"' EXIT
mkdir -p "${_work}/tests"
printf "Describe 'x' {\n  BeforeAll { \$a = 1 }\n  It 'y' { }\n}\n" > "${_work}/tests/Pester.Tests.ps1"
printf "Describe 'x' {\n  It 'y' { Assert-Equal 1 1 }\n}\n" > "${_work}/tests/Harness.Tests.ps1"
_manifest() { printf '[{"id": "fixture.%s", "test": "pwsh -File Invoke-Tests.ps1 -Only %s -ResultFile r.json"}]\n' "$1" "$2" > "${_work}/m.json"; }

t_case "the real manifest names no Pester-style suite as a mutation test"
t_assert_ok _pester_targets "${MANIFEST}" "${WINDOWS_TESTS}"

t_case "a recipe on a Pester-style suite fails and is named"
_manifest pester Pester.Tests.ps1
t_assert_fails _pester_targets "${_work}/m.json" "${_work}/tests"
t_assert_contains "$(_pester_targets "${_work}/m.json" "${_work}/tests")" "fixture.pester -> Pester.Tests.ps1"

t_case "a Pester-style suite inside a comma-separated -Only list is still found"
_manifest listed Harness.Tests.ps1,Pester.Tests.ps1
t_assert_fails _pester_targets "${_work}/m.json" "${_work}/tests"

t_case "a harness-style suite passes"
_manifest harness Harness.Tests.ps1
t_assert_ok _pester_targets "${_work}/m.json" "${_work}/tests"

t_summary
