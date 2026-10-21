#!/usr/bin/env bash
# sccache-launcher.sh; see docs/build-cache-tiers.md#sccache-failure-classes-the-launcher-must-bypass
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
  flaky)  if [ -f "${_SLC_DIR}/flaky.seen" ]; then
            echo "compiled ok" >&2; exit 0
          fi
          : > "${_SLC_DIR}/flaky.seen"
          echo "sccache: encountered fatal error" >&2
          echo "sccache: caused by: No such file or directory (os error 2)" >&2
          exit 1 ;;
  flakyreal) if [ -f "${_SLC_DIR}/flaky.seen" ]; then
            echo "cc1plus: error: 'foo' was not declared in this scope" >&2; exit 1
          fi
          : > "${_SLC_DIR}/flaky.seen"
          echo "sccache: encountered fatal error" >&2
          echo "sccache: caused by: No such file or directory (os error 2)" >&2
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
t_assert_eq "0" "$(cat "${_SLC_DIR}/compiler.calls" 2>/dev/null | wc -l)" "compiler must NOT be called"

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

# The ENOENT class is intermittent, so the launcher retries exactly once before bypassing.
t_case "RETRY: a transient sccache failure is retried and the cache is kept"
rm -f "${_SLC_DIR}/flaky.seen" "${_SLC_DIR}/compiler.calls"
_rc="$(_launcher_run flaky)"
t_assert_eq "0" "${_rc}" "the retry succeeded, so the launcher must report success"
t_assert_ok test ! -f "${_SLC_DIR}/compiler.calls"

t_case "RETRY is bounded: a persistent failure still bypasses to the compiler"
rm -f "${_SLC_DIR}/flaky.seen" "${_SLC_DIR}/compiler.calls"
_rc="$(_launcher_run enoent)"
t_assert_eq "0" "${_rc}"
t_assert_contains "$(cat "${_SLC_DIR}/compiler.calls" 2>/dev/null)" "COMPILER-RAN" \
  "two sccache failures must still fall through, not loop"

t_case "RETRY surfacing a REAL compiler error passes it through, no bypass"
rm -f "${_SLC_DIR}/flaky.seen" "${_SLC_DIR}/compiler.calls"
_rc="$(_launcher_run flakyreal)"
t_assert_eq "1" "${_rc}" "the compiler's own status must survive the retry path"
t_assert_ok test ! -f "${_SLC_DIR}/compiler.calls"

# "tcp:4226" in a bypass line is the cross-container-server bug; see docs/build-cache-tiers.md#the-server-address-must-be-exported-where-the-compiles-run
_launcher_stderr() {
  SCC_MODE="$1" PATH="${_SLC_DIR}:${PATH}" sh "${LAUNCH}" "${_SLC_DIR}/compiler" -c foo.c \
    >/dev/null 2>"${_SLC_DIR}/stderr.txt"
  cat "${_SLC_DIR}/stderr.txt"
}

t_case "the bypass line names the UNIX socket the client addressed"
rm -f "${_SLC_DIR}/compiler.calls"
_msg="$(SCCACHE_SERVER_UDS=/tmp/sccache-test.sock _launcher_stderr enoent)"
t_assert_contains "${_msg}" "server=/tmp/sccache-test.sock" "the bypass must say which server it used"

t_case "with NO address set, the bypass line names the shared TCP default"
rm -f "${_SLC_DIR}/compiler.calls"
env -u SCCACHE_SERVER_UDS -u SCCACHE_SERVER_PORT SCC_MODE=enoent PATH="${_SLC_DIR}:${PATH}" \
  sh "${LAUNCH}" "${_SLC_DIR}/compiler" -c foo.c >/dev/null 2>"${_SLC_DIR}/stderr.txt"
_msg="$(cat "${_SLC_DIR}/stderr.txt")"
t_assert_contains "${_msg}" "server=tcp:4226" "an unset address must be VISIBLE in the log, not implicit"

t_case "the retry-success line names the server too (the counts stay comparable)"
rm -f "${_SLC_DIR}/flaky.seen" "${_SLC_DIR}/compiler.calls"
_msg="$(SCCACHE_SERVER_UDS=/tmp/sccache-test.sock _launcher_stderr flaky)"
t_assert_contains "${_msg}" "retry succeeded (cache kept) [server=/tmp/sccache-test.sock]"

# Only a /bin/sh that drops such names (dash) tells a bash launcher from an sh one.
_sh_drops_hyphens() {
  if env 'A-B=1' /bin/sh -c env 2>/dev/null | grep -q '^A-B=1$'; then return 1; fi
  return 0
}

t_case "a variable whose name has a hyphen reaches sccache (CARGO_BIN_EXE_burn-demos, CON132)"
t_needs "a /bin/sh that drops hyphenated names (dash)" _sh_drops_hyphens
mkdir -p "${_SLC_DIR}/envbin"
printf '#!/usr/bin/env bash\nenv > "%s/sccache.env"\n' "${_SLC_DIR}" > "${_SLC_DIR}/envbin/sccache"
chmod +x "${_SLC_DIR}/envbin/sccache"
# Run through its shebang, as RUSTC_WRAPPER and the CMake launchers do.
env 'CARGO_BIN_EXE_burn-demos=/t/burn-demos' PATH="${_SLC_DIR}/envbin:${PATH}" \
  "${LAUNCH}" "${_SLC_DIR}/compiler" -c foo.c >/dev/null 2>&1
t_assert_contains "$(cat "${_SLC_DIR}/sccache.env" 2>/dev/null)" "CARGO_BIN_EXE_burn-demos=/t/burn-demos" \
  "an integration test of a hyphenated binary loses its path when the launcher drops the variable"

t_summary
