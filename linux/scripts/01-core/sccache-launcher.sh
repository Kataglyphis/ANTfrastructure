#!/bin/sh
# Run the compiler through sccache, but never let sccache's OWN failure kill the
# build: any sccache-internal error (prefixed "sccache:") falls through to
# running the compiler directly; a real compile error passes through untouched.
# sccache prefixes ONLY its own internal failures with "sccache:" — when the
# compiler itself fails, sccache echoes the compiler's diagnostics un-prefixed.
# Why, and the CMake TryCompile root cause: docs/build-cache-tiers.md.
#
# Two failure classes, both observed live:
#   * "sccache: encountered fatal error" — CMake TryCompile deletes its scratch
#     cwd, sccache then spawns the compiler with a dead cwd (ENOENT).
#   * "sccache: error: failed to execute compile" + "sccache: caused by: Failed
#     to send data to or receive data from server" — the sccache SERVER died
#     mid-build (2026-08-30, TVM step under full concurrent-media load). Not
#     matching this class made the launcher hand the dead-server error to ninja
#     as a REAL failure, killing an otherwise-fine build.
# Bypassing is safe in both: worst case the compiler is re-run directly and the
# real (compiler) error surfaces.
#
# Usage: CMAKE_<LANG>_COMPILER_LAUNCHER=/opt/scripts/core/sccache-launcher.sh
#        or CC="/opt/scripts/core/sccache-launcher.sh gcc"
set -u

# /tmp, not the cwd: the cwd is exactly what may have been deleted underneath
# us, and mktemp there would fail for the same reason sccache did.
_err="$(mktemp /tmp/sccache-launcher.XXXXXX 2>/dev/null)" || _err=""

if [ -z "${_err}" ]; then
  # No temp file available — cannot classify the failure, so do not gamble on
  # bypassing. Behave exactly like a plain sccache launcher.
  exec sccache "$@"
fi

sccache "$@" 2>"${_err}"
_rc=$?

if [ "${_rc}" -eq 0 ]; then
  cat "${_err}" >&2
  rm -f "${_err}"
  exit 0
fi

if grep -qE 'sccache: (encountered fatal error|error:|caused by:)' "${_err}" 2>/dev/null; then
  # sccache's own failure. Report it once so it stays visible in the log --
  # a silent bypass would hide a cache that has stopped working -- then run
  # the compiler directly.
  printf 'sccache-launcher: sccache failed on its own account; compiling directly.\n' >&2
  sed 's/^/sccache-launcher:   /' "${_err}" >&2
  rm -f "${_err}"
  exec "$@"
fi

# A real compile error: hand back the compiler's diagnostics and status.
cat "${_err}" >&2
rm -f "${_err}"
exit "${_rc}"
