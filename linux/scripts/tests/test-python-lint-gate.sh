#!/usr/bin/env bash
# Tests for lint-python.sh, the python-lint gate. It cds to a root derived from
# its own path, so each case copies it into a throwaway tree with the RUFF_VERSION
# pin and one subject.py, and proves BOTH tiers: the gate tier must reject with
# rc 1, the advisory tier must report and still pass with rc 0.
# docs/code-quality-tooling.md#proving-a-gate-can-go-red
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
S="$(cd "${TESTS_DIR}/.." && pwd)"
PIN="$(sed -n 's/^RUFF_VERSION=//p' "${S}/01-core/versions.env")"

if ! command -v ruff >/dev/null 2>&1 && ! command -v uvx >/dev/null 2>&1; then
  t_case "ruff or uvx is on PATH (the gate bootstraps from one, and so does this suite)"
  t_assert_ok command -v uvx
  t_summary
fi

# _lint <subject.py body> -> the gate's output plus `rc=<n>`
_lint() {
  local d out rc
  d="$(mktemp -d)"
  mkdir -p "${d}/linux/scripts/01-core" "${d}/docs/scripts"
  cp "${S}/lint-python.sh" "${d}/linux/scripts/"
  printf 'RUFF_VERSION=%s\n' "${PIN}" > "${d}/linux/scripts/01-core/versions.env"
  printf '%s\n' "$1" > "${d}/docs/scripts/subject.py"
  out="$(bash "${d}/linux/scripts/lint-python.sh" 2>&1)"; rc=$?
  rm -rf "${d}"
  printf '%s\nrc=%s\n' "${out}" "${rc}"
}

t_case "the pin the fixture carries is the one versions.env holds"
t_assert_ok test -n "${PIN}"

t_case "an undefined name fails the gate tier"
_out="$(_lint 'print(nope)')"
t_assert_contains "${_out}" "python gate pass failed" "F82 is the whole point of the gate tier"
t_assert_contains "${_out}" "rc=1" "printing findings is not enough; it must exit non-zero"

t_case "a syntax error fails the gate tier"
_out="$(_lint 'def f(:')"
t_assert_contains "${_out}" "rc=1" "an E9 syntax error is a real crash waiting to happen"

t_case "a clean file passes both tiers"
_out="$(_lint 'print("ok")')"
t_assert_contains "${_out}" "gate pass (E9,F63,F7,F82): clean"
t_assert_contains "${_out}" "advisory pass: clean"
t_assert_contains "${_out}" "rc=0" "nothing to report, nothing to fail"

t_case "an advisory-only finding is reported but does not fail"
_out="$(_lint 'import os')"
t_assert_contains "${_out}" "gate pass (E9,F63,F7,F82): clean" "F401 is outside the gate tier"
t_assert_contains "${_out}" "ADVISORY: findings above are informational"
t_assert_contains "${_out}" "rc=0" "the adoption ramp must stay advisory"

t_case "the gate is registered in preflight"
t_assert_contains "$(cat "${S}/preflight.sh")" "python-lint" "an unwired gate is not a gate"

t_summary
