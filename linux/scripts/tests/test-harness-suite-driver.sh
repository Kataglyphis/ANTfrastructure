#!/usr/bin/env bash
# Invoke-HarnessSuite.ps1 on fixture suites; not covered: Windows hosts, or a real suite's own assertions. Arguments select sections (-k failed).
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
t_skip_unless "PowerShell 7" command -v pwsh
WINDOWS="${TESTS_DIR}/../../../windows/scripts"

_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT
mkdir -p "${_work}/tests" "${_work}/modules"
cp "${WINDOWS}/tests/Invoke-HarnessSuite.ps1" "${WINDOWS}/tests/TestHarness.psm1" "${_work}/tests/"
cp "${WINDOWS}/modules/WindowsAst.Common.psm1" "${WINDOWS}/modules/WindowsScripts.Shared.psm1" "${_work}/modules/"

# _suite <name> <body>: a fixture suite, then the driver's exit status and output for it.
_suite() {
  printf '%s\n' "$2" > "${_work}/tests/$1.Tests.ps1"
  pwsh -NoProfile -File "${_work}/tests/Invoke-HarnessSuite.ps1" -Only "$1.Tests.ps1" > "${_work}/out" 2>&1
  echo "$?"
}

_section_passing() {
  t_case "a suite whose assertions hold passes and counts them"
  t_assert_eq 0 "$(_suite pass "Describe 'd' { It 'i' { Assert-Equal 1 1 } }")"
  t_assert_grep "${_work}/out" 'pass\.Tests\.ps1: 1/1 passed'
}

_section_failed() {
  t_case "one failed assertion among passing ones fails the run"
  t_assert_eq 1 "$(_suite fail "Describe 'd' { It 'p' { Assert-Equal 1 1 }; It 'f' { Assert-Equal 1 2 } }")"
  t_assert_grep "${_work}/out" 'fail\.Tests\.ps1: 1/2 passed'
}

_section_empty() {
  t_case "a suite that ran no assertion fails"
  t_assert_eq 1 "$(_suite empty "Describe 'd' { }")"
}

_section_error() {
  t_case "an error outside any assertion fails, whatever passed before it"
  t_assert_eq 1 "$(_suite err "Describe 'd' { It 'p' { Assert-Equal 1 1 } }; Write-Error 'broken suite'")"
}

_section_absent() {
  t_case "an absent suite and a Pester-style suite fail"
  t_assert_rc 1 pwsh -NoProfile -File "${_work}/tests/Invoke-HarnessSuite.ps1" -Only Absent.Tests.ps1
  t_assert_eq 1 "$(_suite pester "Describe 'd' { BeforeAll { }; It 'p' { Assert-Equal 1 1 } }")"
}

t_sections _section_passing _section_failed _section_empty _section_error _section_absent -- "$@"
t_summary
