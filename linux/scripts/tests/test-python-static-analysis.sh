#!/usr/bin/env bash
# Tests for 02-toolchain/python/ci_static_analysis.sh, the driver the reusable
# python-ci-linux.yml lane runs. Until 2026-09-08 all six analysers ran as
# `uv_run <tool> ... 2>/dev/null || true`: findings to /dev/null, verdict
# nowhere. They are a run_gate batch now, and none of what that bought shows in
# a green lane, so it is asserted here: every analyser still runs after one
# fails, the verdict reaches the exit code, findings reach the log, and the two
# rewriting flags stay gone. Exercised against a STUB ci-common.sh (no uv, no
# venv, no network) that records every uv_run call and can fail a chosen one.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SCRIPTS="$(cd "${TESTS_DIR}/.." && pwd)"
SUBJECT="${SCRIPTS}/02-toolchain/python/ci_static_analysis.sh"

_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT

# The driver resolves both of its sources from its own location, so the fixture
# has to reproduce that layout: <tree>/02-toolchain/python/ next to <tree>/01-core/.
TREE="${_work}/tree"
mkdir -p "${TREE}/02-toolchain/python" "${TREE}/01-core"
install -m 0755 "${SUBJECT}" "${TREE}/02-toolchain/python/ci_static_analysis.sh"
install -m 0644 "${SCRIPTS}/01-core/gates.sh" "${TREE}/01-core/gates.sh"
install -m 0644 "${SCRIPTS}/01-core/logging.sh" "${TREE}/01-core/logging.sh"

cat > "${TREE}/02-toolchain/python/ci-common.sh" <<'STUB'
# Stub of the real ci-common.sh: same names, no uv and no network. info/warn/err
# come from the REAL 01-core/logging.sh, the way the driver gets them through
# python_uv.sh -- a second copy of the fallbacks here would be one more of the
# drifted copies this tree keeps finding.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../01-core/logging.sh"
detect_workspace() { WORKSPACE_ROOT="${STUB_WORKSPACE}"; export WORKSPACE_ROOT; }
derive_package_name() { printf '%s' "${1:-fixture_pkg}"; }
uv_venv_ensure() { printf 'venv_ensure %s\n' "$1" >> "${STUB_LOG}"; eval "$4=0"; }
uv_venv_remove() { printf 'venv_remove %s\n' "$1" >> "${STUB_LOG}"; }
uv_sync_project() { printf 'sync %s\n' "$*" >> "${STUB_LOG}"; }
# Every analyser goes through here. It records the whole invocation, prints a
# finding the way a real analyser would, and fails when it matches $STUB_FAIL.
uv_run() {
  printf 'uv_run %s\n' "$*" >> "${STUB_LOG}"
  printf 'FINDING(%s): something to report\n' "$1"
  case "$*" in
    *"${STUB_FAIL}"*) return 1 ;;
  esac
  return 0
}
STUB

OUT=""; rc=0
LOG=""
# _run [failing-invocation-substring]
_run() {
  LOG="$(mktemp "${_work}/log.XXXXXX")"
  OUT="$(cd "${_work}" && STUB_LOG="${LOG}" STUB_WORKSPACE="${_work}" \
    STUB_FAIL="${1:-__nothing_fails__}" \
    bash "${TREE}/02-toolchain/python/ci_static_analysis.sh" 2>&1)"
  rc=$?
}

t_case "with every analyser green the batch is green, and says how much it graded"
_run
t_assert_eq "0" "${rc}" "the driver must be able to pass, or the reds below prove only that it is broken; output was: ${OUT}"
t_assert_contains "${OUT}" "OK (6 gate(s))" \
  "six analysers, counted: a batch that silently shrank to two would still print OK"

t_case "every analyser actually runs (the six are not a comment)"
for _tool in codespell bandit vulture ty; do
  t_assert_contains "$(cat "${LOG}")" "uv_run ${_tool}"
done
t_assert_contains "$(cat "${LOG}")" "uv_run ruff check"
t_assert_contains "$(cat "${LOG}")" "uv_run ruff format"

t_case "findings reach the log instead of /dev/null"
t_assert_contains "${OUT}" "FINDING(bandit)" \
  "the old chain sent every analyser's diagnostics to /dev/null, so a finding could not be read anywhere"

t_case "one failing analyser FAILS the run -- the verdict reaches the exit code"
_run "bandit -r"
t_assert_eq "1" "${rc}" "'|| true' per tool is exactly the suppression this batch replaced"
t_assert_contains "${OUT}" "bandit" "the failing gate must be named"
t_assert_contains "${OUT}" "FAILED (1 of 6)" "and counted against the six that ran"

t_case "the analysers AFTER the failing one still run: one push names every finding"
t_assert_contains "$(cat "${LOG}")" "uv_run ty check" \
  "stopping at the first failure costs one push per finding, which is why run_gate records instead of raising"
t_assert_contains "$(cat "${LOG}")" "uv_run ruff format"

t_case "the venv teardown still happens when a gate failed"
t_assert_contains "$(cat "${LOG}")" "venv_remove" \
  "assert_gates sits after the teardown so a red run does not leak the fixture venv"

t_case "ruff check does not REWRITE the tree it is grading"
_run
t_assert_contains "$(cat "${LOG}")" "uv_run ruff check --no-fix" \
  "--fix repaired the working tree and then graded the repaired copy, so the step could only be green"
t_assert_eq "" "$(grep -F -e 'ruff check --fix' "${LOG}" || true)"

t_case "ruff format reports a diff instead of reformatting"
t_assert_contains "$(cat "${LOG}")" "uv_run ruff format --check --diff" \
  "a bare 'ruff format' rewrites the files and exits 0; the finding then shows up in git status, not in the gate"

t_summary
