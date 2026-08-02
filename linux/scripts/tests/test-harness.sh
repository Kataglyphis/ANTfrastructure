#!/usr/bin/env bash
# test-harness.sh — minimal assert/reporting helpers for linux/scripts tests.
# The bash counterpart of windows/scripts/tests/TestHarness.psm1: plain bash,
# zero dependencies, source it from a test-*.sh file and call t_summary last.
#
#   source "$(dirname "${BASH_SOURCE[0]}")/test-harness.sh"
#   t_case "cross_sdk_tag formats the arch suffix"
#   t_assert_eq "repo:cross-sdk-arm64" "$(cross_sdk_tag arm64)"
#   ...
#   t_summary   # exits non-zero if any assertion failed
[ -n "${_TEST_HARNESS_SH_LOADED:-}" ] && return 0
_TEST_HARNESS_SH_LOADED=1

_T_RUN=0
_T_FAILED=0
_T_CASE=""

t_case() { _T_CASE="$1"; }

_t_fail() {
  _T_FAILED=$((_T_FAILED + 1))
  printf '  \033[0;31mFAIL\033[0m [%s] %s\n' "${_T_CASE:-?}" "$1" >&2
}

_t_pass() { :; }

# t_assert_eq <expected> <actual> [message]
t_assert_eq() {
  _T_RUN=$((_T_RUN + 1))
  if [ "$1" = "$2" ]; then _t_pass; else
    _t_fail "${3:-values differ}: expected '$1', got '$2'"
  fi
}

# t_assert_contains <haystack> <needle> [message]
t_assert_contains() {
  _T_RUN=$((_T_RUN + 1))
  case "$1" in *"$2"*) _t_pass ;; *) _t_fail "${3:-missing substring}: '$2' not in '$1'" ;; esac
}

# t_assert_ok <command...>  — command must succeed
t_assert_ok() {
  _T_RUN=$((_T_RUN + 1))
  if "$@" >/dev/null 2>&1; then _t_pass; else _t_fail "expected success: $*"; fi
}

# t_assert_fails <command...>  — command must fail
t_assert_fails() {
  _T_RUN=$((_T_RUN + 1))
  if "$@" >/dev/null 2>&1; then _t_fail "expected failure: $*"; else _t_pass; fi
}

t_summary() {
  if [ "${_T_FAILED}" -gt 0 ]; then
    printf '  %d/%d assertion(s) FAILED\n' "${_T_FAILED}" "${_T_RUN}" >&2
    exit 1
  fi
  printf '  %d assertion(s) passed\n' "${_T_RUN}"
  exit 0
}
