#!/usr/bin/env bash
# Tests for lint-python.sh, the python-lint gate. It cds to a root derived from
# its own path, so each case builds a throwaway tree and runs the REAL script in
# it -- proving both TIERS (gate hard-fails, advisory reports and passes) and the
# TARGET SET (plain .py plus heredoc Python, non-Python heredocs excluded).
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

# A throwaway repo root carrying the gate and its pin, printed on stdout so
# callers can drop fixtures into it. The extractor is copied in only by _targets:
# it is itself first-party Python, so its advisory findings would drown the
# advisory-clean assertion below.
_mkroot() {
  local d
  d="$(mktemp -d)"
  mkdir -p "${d}/linux/scripts/01-core" "${d}/docs/scripts"
  cp "${S}/lint-python.sh" "${d}/linux/scripts/"
  printf 'RUFF_VERSION=%s\n' "${PIN}" > "${d}/linux/scripts/01-core/versions.env"
  printf '%s\n' "${d}"
}

# _run <root> -> the gate's output plus `rc=<n>`; consumes the root.
_run() {
  local out rc
  out="$(bash "$1/linux/scripts/lint-python.sh" 2>&1)"; rc=$?
  rm -rf "$1"
  printf '%s\nrc=%s\n' "${out}" "${rc}"
}

# _lint <subject.py body> -> the gate's output plus `rc=<n>`
_lint() {
  local d
  d="$(_mkroot)"
  printf '%s\n' "$1" > "${d}/docs/scripts/subject.py"
  _run "${d}"
}

# _targets <subject.py body> <heredoc python body> -> the gate's output plus rc.
# The tree carries all three target shapes at once: a plain .py, a directly-run
# heredoc opened on line 2 of probe.sh, and a cat'ed TPL_PY_* family that is nginx
# config, not Python, and must never reach ruff. Openers are printf ARGUMENTS so
# this suite is not itself an extraction target. docs/code-quality-tooling.md
_targets() {
  local d
  d="$(_mkroot)"
  cp "${S}/extract_embedded_python.py" "${d}/linux/scripts/"
  printf '%s\n' "$1" > "${d}/docs/scripts/subject.py"
  { printf 'probe() {\n'
    printf '  python3 - %s\n' "<<'PY'"
    printf '%s\nPY\n}\n' "$2"
  } > "${d}/linux/scripts/probe.sh"
  { printf 'emit_head() {\n'
    printf '  cat %s\n' "<<'TPL_PY_HEAD'"
    printf 'location / {\nTPL_PY_HEAD\n}\n'
    printf 'emit_tail() {\n'
    printf '  cat %s\n' "<<'TPL_PY_TAIL'"
    printf '  proxy_pass http://app;\n}\nTPL_PY_TAIL\n}\n'
  } > "${d}/linux/scripts/tpl.sh"
  _run "${d}"
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

t_case "a clean tree of all three target shapes passes"
_out="$(_targets 'print("ok")' 'print("ok")')"
t_assert_contains "${_out}" "gate pass (E9,F63,F7,F82): clean" \
  "the nginx TPL_PY_* family must not be linted as Python"
t_assert_contains "${_out}" "rc=0"

t_case "a gate-tier error in a plain .py still fails with heredocs in the tree"
_out="$(_targets 'print(nope_in_py)' 'print("ok")')"
t_assert_contains "${_out}" "nope_in_py" "the plain-.py target must survive the extraction step"
t_assert_contains "${_out}" "rc=1"

t_case "a gate-tier error inside a shell heredoc fails the gate"
_out="$(_targets 'print("ok")' 'print(nope_in_heredoc)')"
t_assert_contains "${_out}" "nope_in_heredoc" \
  "switching extraction off leaves ~775 heredoc lines outside the gate, silently"
t_assert_contains "${_out}" "python gate pass failed"
t_assert_contains "${_out}" "rc=1"

t_case "the heredoc finding names its shell file and line"
_out="$(_targets 'print("ok")' 'print(nope_in_heredoc)')"
t_assert_contains "${_out}" "probe__2.py:1:" \
  "the extracted name maps the finding back to probe.sh's opener line 2, body line 1"

t_case "the gate is registered in preflight"
t_assert_contains "$(cat "${S}/preflight.sh")" "python-lint" "an unwired gate is not a gate"

t_summary
