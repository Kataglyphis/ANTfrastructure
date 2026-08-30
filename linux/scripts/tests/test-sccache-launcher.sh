#!/usr/bin/env bash
# Tests for 01-core/sccache-launcher.sh — the guarded launcher whose bypass
# decision decides whether an sccache internal failure costs cache hits or the
# whole build.
#
# WHY THIS SUITE EXISTS (2026-08-30)
# ----------------------------------
# The launcher only bypassed on "sccache: encountered fatal error" (the CMake
# TryCompile ENOENT class). A second failure class was observed live on the
# first F2 media validation build: the sccache SERVER died mid-build
# ("sccache: error: failed to execute compile" / "caused by: Failed to send
# data to or receive data from server"), which the launcher did NOT classify as
# sccache-internal — so it handed the dead-server error to ninja as a REAL
# failure and killed the TVM step. These tests pin the classification:
#   * BOTH sccache failure classes bypass to a direct compiler run
#   * a REAL compiler error passes through untouched (compiler never re-run)
#   * a clean compile passes through
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
LAUNCH="${TESTS_DIR}/../01-core/sccache-launcher.sh"

_SLC_DIR="${TMPDIR:-/tmp}/scl-test.$$"
mkdir -p "${_SLC_DIR}"
trap 'rm -rf "${_SLC_DIR}"' EXIT

# Fake sccache (behavior per $SCC_MODE) + a recording fake compiler.
cat > "${_SLC_DIR}/sccache" <<'EOF'
#!/bin/sh
case "${SCC_MODE:-ok}" in
  enoent) echo "sccache: encountered fatal error" >&2
          echo "sccache: caused by: No such file or directory (os error 2)" >&2
          exit 1 ;;
  server) echo "sccache: error: failed to execute compile" >&2
          echo "sccache: caused by: Failed to send data to or receive data from server" >&2
          echo "sccache: caused by: failed to fill whole buffer" >&2
          exit 1 ;;
  realerr) echo "cc1plus: error: 'foo' was not declared in this scope" >&2
           exit 1 ;;
  *)      echo "compiled ok" >&2
          exit 0 ;;
esac
EOF
cat > "${_SLC_DIR}/compiler" <<'EOF'
#!/bin/sh
echo "COMPILER-RAN" >> "${_SLC_DIR}/compiler.calls"
exit 0
EOF
chmod +x "${_SLC_DIR}/sccache" "${_SLC_DIR}/compiler"
export _SLC_DIR

_launcher_run() {
  local mode="$1"
  SCC_MODE="${mode}" PATH="${_SLC_DIR}:${PATH}" sh "${LAUNCH}" "${_SLC_DIR}/compiler" -c foo.c >/dev/null 2>&1
  printf '%d' "$?"
}

t_case "ENOENT class: sccache's own failure → launcher bypasses to the compiler"
rm -f "${_SLC_DIR}/compiler.calls"
_rc="$(_launcher_run enoent)"
t_assert_eq "0" "${_rc}" "bypass must exit 0 (compiler ran directly)"
t_assert_eq "1" "$(wc -l < "${_SLC_DIR}/compiler.calls" 2>/dev/null || echo 0)" "compiler must have been called once"

t_case "SERVER-DEATH class: same bypass (the 2026-08-30 TVM failure)"
rm -f "${_SLC_DIR}/compiler.calls"
_rc="$(_launcher_run server)"
t_assert_eq "0" "${_rc}" "server-death must also bypass (exit 0)"
t_assert_eq "1" "$(wc -l < "${_SLC_DIR}/compiler.calls" 2>/dev/null || echo 0)" "compiler must have been called once"

t_case "REAL compiler error: passes through, compiler NOT re-run"
rm -f "${_SLC_DIR}/compiler.calls"
_rc="$(_launcher_run realerr)"
t_assert_eq "1" "${_rc}" "real error must keep sccache's non-zero exit"
t_assert_eq "0" "$(wc -l < "${_SLC_DIR}/compiler.calls" 2>/dev/null || echo 0)" "compiler must NOT be called"

t_case "clean compile: passes through with rc 0, no bypass"
rm -f "${_SLC_DIR}/compiler.calls"
_rc="$(_launcher_run ok)"
t_assert_eq "0" "${_rc}"
t_case "MUTATION: a launcher that only matches 'encountered fatal error' fails the server-death case"
rm -f "${_SLC_DIR}/compiler.calls"
# The OLD behaviour: grep -q 'sccache: encountered fatal error' only.
_old_bypass() {
  local err="$1"
  if grep -q 'sccache: encountered fatal error' "${err}" 2>/dev/null; then return 0; fi
  return 1
}
_errf="${_SLC_DIR}/server.err"
printf 'sccache: error: failed to execute compile\ncaused by: Failed to send data to or receive data from server\n' > "${_errf}"
_old_bypass "${_errf}" && _old_verdict="bypass" || _old_verdict="no-bypass"
t_assert_eq "no-bypass" "${_old_verdict}" "old classification would NOT bypass — the bug"

t_summary
