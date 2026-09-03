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

_sccache_own_failure() {
  grep -qE 'sccache: (encountered fatal error|error:|caused by:)' "$1" 2>/dev/null
}

if _sccache_own_failure "${_err}"; then
  # YB: this class is INTERMITTENT and parallel-only, and the same argv succeeds
  # right after (see the header). So retry ONCE before giving up the cache entry:
  # a bypass compiles fine but throws the cache away, and that is thousands of
  # units per chain. The retry also measures the class -- "retry succeeded" means
  # transient, "failed twice" means it is not.
  sccache "$@" 2>"${_err}"
  _rc2=$?
  if [ "${_rc2}" -eq 0 ]; then
    printf 'sccache-launcher: sccache failed once, retry succeeded (cache kept).\n' >&2
    cat "${_err}" >&2
    rm -f "${_err}"
    exit 0
  fi
  if _sccache_own_failure "${_err}"; then
    # Still sccache's own failure. Report it once so it stays visible in the log --
    # a silent bypass would hide a cache that has stopped working -- then run
    # the compiler directly.
    printf 'sccache-launcher: sccache failed twice on its own account; compiling directly.\n' >&2
    sed 's/^/sccache-launcher:   /' "${_err}" >&2
    rm -f "${_err}"
    exec "$@"
  fi
  # The retry surfaced a REAL compiler error: hand it back, do not re-run.
  cat "${_err}" >&2
  rm -f "${_err}"
  exit "${_rc2}"
fi

# A real compile error: hand back the compiler's diagnostics and status.
cat "${_err}" >&2
rm -f "${_err}"
exit "${_rc}"
