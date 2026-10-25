#!/usr/bin/env bash
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
RUNNER="${TESTS_DIR}/../wsl-quality.sh"

_expect_rejected() {
  local expected="$1" label="$2" status
  shift 2
  if bash "${RUNNER}" "$@" >/dev/null 2>&1; then
    status=0
  else
    status=$?
  fi
  t_assert_eq "${expected}" "${status}" "${label}"
}

t_case "WSL quality runner parses without installing host packages"
t_assert_ok bash -n "${RUNNER}"

t_case "help documents setup, full checks and combined use"
_help="$(bash "${RUNNER}" --help)"
t_assert_contains "${_help}" "setup" "setup is callable from WSL"
t_assert_contains "${_help}" "check" "all local quality checks have one entry point"
t_assert_contains "${_help}" "all" "setup and check can run together"

t_case "setup resolves its tools and Python packages from repository pins"
_source="$(cat "${RUNNER}")"
t_assert_contains "${_source}" 'install-uv --version "${UV_VERSION}"' "uv uses the shared release pin"
t_assert_contains "${_source}" 'uv sync --project quality --locked' "Python tools come from the locked quality project"
t_assert_contains "${_source}" 'PSScriptAnalyzer' "PowerShell lint installs its pinned analyzer"

t_case "check runs mutation proofs after the non-mutation preflight"
t_assert_contains "${_source}" 'PREFLIGHT_SKIP=mutations' "preflight mutation work is not duplicated"
t_assert_contains "${_source}" 'verify_mutations.py" --jobs' "the whole mutation manifest still runs"
t_assert_contains "${_source}" 'logs/code-quality/wsl' "run logs stay in the ignored log tree"

t_case "unknown commands fail before touching the host"
_expect_rejected 2 "bad command must not start an install" unknown

t_case "invalid worker counts fail before touching the host"
_expect_rejected 1 "a zero-worker test run must be rejected" check --jobs 0

t_summary
