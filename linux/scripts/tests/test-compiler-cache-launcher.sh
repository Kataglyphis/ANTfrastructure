#!/usr/bin/env bash
# Tests for 01-core/common.sh compiler_cache_launcher — the function whose
# STDOUT becomes CC/CXX.
#
# WHY THIS SUITE EXISTS (2026-08-26)
# ----------------------------------
# compiler_cache_launcher returns the launcher NAME on stdout and callers do
# CC="$(compiler_cache_launcher) gcc". The helpers it calls log with info(),
# which writes to fd 1 (logging.sh:77) — so an unredirected helper leaks its
# log line into the command substitution. That shipped for exactly one build:
# GCC was configured with
#   CC="[INFO] Using sccache with SCCACHE_DIR=... (cap 30G)sccache gcc"
# and died as "configure: error: C compiler cannot create executables", a
# message that points nowhere near the actual cause.
#
# These tests assert the CONTRACT rather than the implementation: whatever the
# function prints on stdout must be a bare launcher name, and nothing else.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"

# Load only the function under test, with stub helpers around it, so the suite
# stays a pure unit test (no apt, no sccache server, no network).
_load_launcher() {
  # shellcheck disable=SC1090
  source "${TESTS_DIR}/../01-core/logging.sh"
  eval "$(sed -n '/^compiler_cache_launcher() {/,/^}/p' "${TESTS_DIR}/../01-core/common.sh")"
}

# ── the leak that actually happened ──────────────────────────────────────────
t_case "sccache branch: stdout carries ONLY the launcher name"
(
  _load_launcher
  ensure_sccache_env() { info "Using sccache with SCCACHE_DIR=/var/cache/sccache (cap 30G)"; return 0; }
  ensure_ccache_env()  { info "Using ccache"; return 0; }
  compiler_cache_launcher 2>/dev/null
) > "${TMPDIR:-/tmp}/ccl_out.$$" 2>/dev/null
_out="$(cat "${TMPDIR:-/tmp}/ccl_out.$$")"; rm -f "${TMPDIR:-/tmp}/ccl_out.$$"
t_assert_eq "${_out}" "sccache"

t_case "ccache fallback: stdout carries ONLY the launcher name"
(
  _load_launcher
  ensure_sccache_env() { info "sccache unavailable"; return 1; }
  ensure_ccache_env()  { info "Using ccache with CCACHE_DIR=/var/cache/ccache"; return 0; }
  command() { if [ "${2:-}" = "ccache" ]; then return 0; fi; builtin command "$@"; }
  compiler_cache_launcher 2>/dev/null
) > "${TMPDIR:-/tmp}/ccl_out2.$$" 2>/dev/null
_out2="$(cat "${TMPDIR:-/tmp}/ccl_out2.$$")"; rm -f "${TMPDIR:-/tmp}/ccl_out2.$$"
t_assert_eq "${_out2}" "ccache"

# ── the property that matters, stated directly ───────────────────────────────
t_case "output is a single bare token — never a log line, never multi-word"
case "${_out}" in
  *' '*|*'['*|*$'\n'*) t_assert_eq "polluted: ${_out}" "single bare token" ;;
  *)                   t_assert_eq "ok" "ok" ;;
esac

t_case "output never contains a log prefix"
case "${_out}${_out2}" in
  *INFO*|*WARN*|*ERROR*) t_assert_eq "log prefix leaked" "no log prefix" ;;
  *)                     t_assert_eq "ok" "ok" ;;
esac

# ── mutation check: prove the test can actually FAIL ─────────────────────────
# A guard that cannot fail is worse than none, so demonstrate the detector
# fires on the exact pre-fix behaviour (helper stdout NOT redirected).
t_case "MUTATION: an unredirected helper is detected as pollution"
_leaky="$(
  source "${TESTS_DIR}/../01-core/logging.sh"
  ensure_sccache_env() { info "Using sccache with SCCACHE_DIR=/x (cap 30G)"; return 0; }
  # deliberately WITHOUT the >&2 redirect — the shape of the shipped bug
  leaky() { if ensure_sccache_env; then printf '%s' sccache; fi; }
  leaky 2>/dev/null
)"
case "${_leaky}" in
  *INFO*) t_assert_eq "detected" "detected" ;;
  *)      t_assert_eq "mutation NOT detected (${_leaky})" "detected" ;;
esac

t_summary
