#!/usr/bin/env bash
# Fake tools check quality argv and cold-import companions; no formatter, compiler, coverage tool or package download runs.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
QUALITY="${1:-${TESTS_DIR}/../lib/code-quality.sh}"
COVERAGE="${2:-${TESTS_DIR}/../lib/coverage.sh}"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/lib" "${WORK}/01-core"
cp "${QUALITY}" "${WORK}/lib/code-quality.sh"
cp "${COVERAGE}" "${WORK}/lib/coverage.sh"
for companion in log-bootstrap.sh cli-value-options.sh; do cp "${TESTS_DIR}/../lib/${companion}" "${WORK}/lib/"; done
cp "${TESTS_DIR}/../01-core/tool-checks.sh" "${WORK}/01-core/"
info() { :; }
warn() { :; }
err() { printf 'fixture err:%s\n' "$*" >&2; return 29; }
has_tool() { printf 'caller has_tool\n'; }
require_tools() { printf '%s\n' "$*" > "${WORK}/required"; }
before_options="$-"
# shellcheck source=/dev/null
source "${WORK}/lib/code-quality.sh"
# shellcheck source=/dev/null
source "${WORK}/lib/coverage.sh"
t_case 'cold imports keep caller tool overrides and shell options'
t_assert_eq "${before_options}" "$-"
t_assert_eq 'caller has_tool' "$(has_tool fixture)"
clang-tidy() { printf '%s\0' "$@" > "${WORK}/argv"; return "${tool_status}"; }
gcovr() { printf '%s\0' "$@" > "${WORK}/argv"; return "${tool_status}"; }
_assert_argv() {
  local expected=("$@") actual=() index
  mapfile -d '' -t actual < "${WORK}/argv"
  t_assert_eq "${#expected[@]}" "${#actual[@]}"
  for index in "${!expected[@]}"; do t_assert_eq "${expected[index]}" "${actual[index]-absent}"; done
}
t_case 'clang-tidy leaves an empty source list untouched'
rm -f "${WORK}/argv"
code_quality_run_clang_tidy 'database path'
t_assert_eq 1 "$(t_rc test -e "${WORK}/argv")"
t_case 'clang-tidy keeps configured argument order, spaces, newlines and the fix flag'
CODE_QUALITY_CLANG_TIDY_ARGS=('' '--header-filter=source tree/.*' '' $'line\nargument')
export CODE_QUALITY_CLANG_TIDY_FIX=true; tool_status=7; status=0
code_quality_run_clang_tidy 'database path' 'source file.cpp' '--literal' || status=$?
t_assert_eq 7 "${status}"
_assert_argv -p 'database path' '--header-filter=source tree/.*' $'line\nargument' -fix 'source file.cpp' '--literal'
t_assert_eq '' "${CODE_QUALITY_CLANG_TIDY_ARGS[0]}"
unset CODE_QUALITY_CLANG_TIDY_ARGS CODE_QUALITY_CLANG_TIDY_FIX
tool_status=0
code_quality_run_clang_tidy db src.cpp
_assert_argv -p db src.cpp
t_case 'gcovr prefixes only nonempty excludes, then extras and output'
COVERAGE_GCOVR_EXCLUDES=('' 'third party/.*' '' $'line\nscope')
COVERAGE_GCOVR_EXTRA_ARGS=('' '--html-details' '--title= a b' '')
export COVERAGE_GCOVR_OUTPUT='report path.xml'; tool_status=9; status=0
coverage_run_gcovr 'root tree' || status=$?
t_assert_eq 9 "${status}"
t_assert_eq gcovr "$(cat "${WORK}/required")"
_assert_argv -r 'root tree' --exclude 'third party/.*' --exclude $'line\nscope' --html-details '--title= a b' --output 'report path.xml'
t_assert_eq '' "${COVERAGE_GCOVR_EXCLUDES[0]}"
t_assert_eq 4 "${#COVERAGE_GCOVR_EXTRA_ARGS[@]}"
unset COVERAGE_GCOVR_EXCLUDES COVERAGE_GCOVR_EXTRA_ARGS COVERAGE_GCOVR_OUTPUT
tool_status=0
coverage_run_gcovr
_assert_argv -r .
t_summary
