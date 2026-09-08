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

# A mistyped assertion used to be INVISIBLE: bash printed "command not found",
# the test file kept going, and t_summary still reported every assertion passed.
# Found 2026-09-02 by typing t_assert_fail (the real name is t_assert_fails) --
# three assertions vanished and the suite stayed green. Turn that into a
# counted failure so a typo can never masquerade as coverage.
# bash runs this handler in a SEPARATE EXECUTION ENVIRONMENT, so incrementing a
# counter here is lost -- the first cut of this did exactly that and still
# printed "passed". Record on disk; t_summary reads the marker.
_T_UNKNOWN_MARK="${TMPDIR:-/tmp}/.t-harness-unknown.$$"
rm -f "${_T_UNKNOWN_MARK}" 2>/dev/null || true

command_not_found_handle() {
  # ONLY t_* names. Suites legitimately probe for absent binaries (and discard
  # that stderr), so counting every missing command turned 2 healthy suites red
  # when this was first written. The hole being closed is narrower: a mistyped
  # ASSERTION silently doing nothing.
  case "$1" in
    t_*)
      printf '%s\n' "$1" >> "${_T_UNKNOWN_MARK}"
      printf '  \033[0;31mFAIL\033[0m [%s] unknown assertion: %s\n' "${_T_CASE:-?}" "$1" >&2
      ;;
  esac
  return 127
}

_t_fail() {
  _T_FAILED=$((_T_FAILED + 1))
  printf '  \033[0;31mFAIL\033[0m [%s] %s\n' "${_T_CASE:-?}" "$1" >&2
}

_t_pass() { :; }

# t_fake_elf <path> <e_machine> — a 64-byte ELF header, which is all any gate in
# this tree reads of a binary: magic, EI_CLASS/EI_DATA, e_type, e_machine. One
# owner, so a suite needing a binary of a given arch never ships one.
t_fake_elf() {
  python3 -c 'import sys
m = int(sys.argv[2])
h = bytearray(64)
h[0:4] = b"\x7fELF"; h[4] = 2; h[5] = 1
h[16:18] = (2).to_bytes(2, "little")
h[18:20] = m.to_bytes(2, "little")
open(sys.argv[1], "wb").write(bytes(h))' "$1" "$2"
}

# t_fn_src <file> <function> — the source of one top-level `name() {` … `}`
# function, for suites that run a build-stage helper off-target with its
# collaborators stubbed. Returns 1 when the function is gone -- callers do
# `_fn_src="$(t_fn_src f fn)" || exit 1`, since a subshell cannot end the suite.
t_fn_src() {
  local _src
  _src="$(awk -v fn="$2" '$0 == fn "() {" {p=1} p {print} p && /^}$/ {exit}' "$1")"
  [ -n "${_src}" ] || { echo "FAIL: $2 not found in $1" >&2; return 1; }
  printf '%s\n' "${_src}"
}

# t_gate_tree <module>... — a throwaway root holding linux/scripts/<module> for each
# named module, for a gate that derives its own root from __file__. Prints the root;
# the caller adds its fixture and removes it. Second owner of a shape two suites had
# copied. docs/code-quality-tooling.md#the-mutation-gate-mutations
_T_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
t_gate_tree() {
  local root m; root="$(mktemp -d)"
  for m in "$@"; do
    install -D -m 0644 "${_T_SCRIPTS}/${m}" "${root}/linux/scripts/${m}"
  done
  printf '%s' "${root}"
}

# t_out <command...> — combined stdout+stderr, to assert on messages
t_out() { "$@" 2>&1; }
# t_rc <command...> — the exit code as text, for t_assert_eq
t_rc()  { "$@" >/dev/null 2>&1; echo $?; }

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

# Both take a COMMAND and no message, so `t_assert_fails test -f X "why"` runs
# `test -f X why` -- which fails for the WRONG reason (bash: "too many arguments",
# rc 2) and passes vacuously. Four of those were written and caught by review in
# one wave; this is the harness catching the next one. Only `test`/`[` report a
# usage error as rc 2, which is exactly the shape being caught.
_t_usage_error() {
  [ "$2" = "2" ] || return 1
  case "$1" in test|'[') return 0 ;; *) return 1 ;; esac
}

# Both assertions run the command the same way; only the verdict differs.
# $1 = the rc that means PASS ("0" for t_assert_ok, anything else for t_assert_fails).
_t_assert_run() {
  local name="$1" want="$2" verdict="$3"; shift 3
  local _rc=0
  _T_RUN=$((_T_RUN + 1))
  "$@" >/dev/null 2>&1 || _rc=$?
  if _t_usage_error "$1" "${_rc}"; then
    _t_fail "malformed test expression: $* -- ${name} takes a COMMAND and no message, so the message became an ARGUMENT and this verdict is about the wrong thing"
  elif { [ "${want}" = "0" ] && [ "${_rc}" -eq 0 ]; } \
    || { [ "${want}" != "0" ] && [ "${_rc}" -ne 0 ]; }; then
    _t_pass
  else
    _t_fail "expected ${verdict}: $*"
  fi
}

# t_assert_ok <command...>  — command must succeed
t_assert_ok()    { _t_assert_run t_assert_ok 0 success "$@"; }

# t_assert_fails <command...>  — command must fail
t_assert_fails() { _t_assert_run t_assert_fails 1 failure "$@"; }

t_summary() {
  local _unknown=0
  if [ -s "${_T_UNKNOWN_MARK:-/nonexistent}" ]; then
    _unknown="$(wc -l < "${_T_UNKNOWN_MARK}" | tr -d ' ')"
    _T_FAILED=$((_T_FAILED + _unknown))
    printf '  %s unknown command(s)/assertion(s) — a typo is NOT coverage\n' "${_unknown}" >&2
    rm -f "${_T_UNKNOWN_MARK}" 2>/dev/null || true
  fi
  if [ "${_T_FAILED}" -gt 0 ]; then
    printf '  %d/%d assertion(s) FAILED\n' "${_T_FAILED}" "${_T_RUN}" >&2
    exit 1
  fi
  # Zero assertions is a FAILURE, not a pass: a gutted suite (commented-out
  # asserts, an early-return source guard) used to print "0 assertion(s)
  # passed" and stay green — coverage silently dropping to nothing.
  if [ "${_T_RUN}" -eq 0 ]; then
    printf '  SUITE RAN ZERO ASSERTIONS — treating as failure\n' >&2
    exit 1
  fi
  printf '  %d assertion(s) passed\n' "${_T_RUN}"
  exit 0
}

# t_gate_probe <module.py> <<'PY' … PY -> the snippet's stdout, with the REAL shipped
# gate bound to `g`. Every other case builds a throwaway tree, so this is the only way
# to assert against the scan set that actually ships. Two suites grew the same importlib
# preamble independently and the dupes gate caught the second copy.
# docs/code-quality-tooling.md#code-to-docs-pointers-doc-links
t_gate_probe() {
  local _mod="$1"
  {
    printf 'import importlib.util, pathlib, tempfile\n'
    printf 'spec = importlib.util.spec_from_file_location("g", "%s")\n' "${_mod}"
    printf 'g = importlib.util.module_from_spec(spec); spec.loader.exec_module(g)\n'
    cat
  } | "${PREFLIGHT_PYTHON:-python3}" -
}
