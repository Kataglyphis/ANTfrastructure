#!/bin/sh
# ==============================================================================
# sccache-launcher.sh — run the compiler through sccache, but never let
# sccache's OWN failure kill the build.
#
# THE PROBLEM THIS SOLVES (2026-08-26, proven)
# --------------------------------------------
# sccache differs from ccache in one decisive way: where ccache falls through
# and execs the compiler, sccache exits non-zero. During the ccache->sccache
# switch that turned two harmless situations into build breaks, both inside
# CMake's TryCompile probes:
#
#   sccache: error: while hashing the input file
#     '.../CMakeFiles/CMakeScratch/TryCompile-XXXX/testCCompiler.c'
#   sccache: error: failed to spawn Command { std: cd
#     '.../CMakeFiles/CMakeScratch/TryCompile-XXXX' && ... }
#   caused by: No such file or directory (os error 2)
#
# Root cause, measured: CMake creates a TryCompile scratch directory, compiles
# in it, and DELETES it. sccache then spawns the compiler with that directory
# as the working directory — and spawning a process whose cwd no longer exists
# fails with ENOENT. Verified directly:
#   python3 -c "spawn /bin/true with cwd=<deleted dir>" -> errno 2
# That is why the failure moved between OpenCV, onnxruntime and IREE (whichever
# probe lost the race) and why it never reproduced against directories that
# persist.
#
# WHAT THIS DOES
# --------------
# Try sccache. If it succeeds, done — the cache works exactly as before. If it
# fails, look at WHOSE failure it was:
#   * "sccache: encountered fatal error"  -> sccache broke, not the code.
#     Re-run the compiler directly so the build continues uncached.
#   * anything else                        -> a REAL compile error. Pass the
#     compiler's own stderr and exit status through untouched.
# The distinction matters: blindly retrying would hide genuine compile errors
# behind a second run, which is worse than the problem being fixed.
#
# This keeps the owner directive intact — sccache is still tried for every
# compile — while removing the one behaviour that made it unusable here.
#
# Usage: CMAKE_<LANG>_COMPILER_LAUNCHER=/opt/scripts/core/sccache-launcher.sh
#        or CC="/opt/scripts/core/sccache-launcher.sh gcc"
# ==============================================================================
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

if grep -q 'sccache: encountered fatal error' "${_err}" 2>/dev/null; then
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
