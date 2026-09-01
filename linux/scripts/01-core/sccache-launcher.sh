#!/bin/sh
# Run the compiler through sccache, but never let sccache's OWN failure kill the
# build: any sccache-internal error (prefixed "sccache:") falls through to
# running the compiler directly; a real compile error passes through untouched.
# sccache prefixes ONLY its own internal failures with "sccache:" -- when the
# compiler itself fails, sccache echoes the compiler's diagnostics un-prefixed.
# Cache-tier design: docs/build-cache-tiers.md.
#
# Two failure classes, both measured in the 2026-09-01 run (3062 bypasses):
#   * 2952x "sccache: encountered fatal error" + "failed to spawn <compiler>
#     ... No such file or directory (os error 2)" on sccache's own -E
#     preprocessor pass. Intermittent (~10-40% of compiles) in the heavily
#     parallel steps only; the compiler path is absolute and the cwd is a live
#     build dir, and the direct fallback of that same argv succeeds right after,
#     so neither a missing compiler nor sccache's scrubbed env explains it. Root
#     cause is inside sccache's spawn and is still open -- do NOT re-derive one
#     from this message alone.
#   * 110x "sccache: error: failed to execute compile" + "Failed to send data to
#     or receive data from server" -- the sccache server died mid-build.
# Bypassing is safe in both: worst case the compiler is re-run directly and the
# real (compiler) error surfaces.
#
# Usage: CMAKE_<LANG>_COMPILER_LAUNCHER=/opt/scripts/core/sccache-launcher.sh
#        or CC="/opt/scripts/core/sccache-launcher.sh gcc"
set -u

# /tmp, not the cwd: a build cwd may be read-only or gone by the time we run.
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
