#!/bin/sh
# sccache's own failures never kill the build. docs/build-cache-tiers.md#sccache-failure-classes-the-launcher-must-bypass
_err="$(mktemp /tmp/sccache-launcher.XXXXXX 2>/dev/null)" || _err=""

if [ -z "${_err}" ]; then
  # Without a temp file a failure cannot be classified, so behave like plain sccache.
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
  # Intermittent class: retry once before losing the cache entry. See docs link.
  sccache "$@" 2>"${_err}"
  _rc2=$?
  if [ "${_rc2}" -eq 0 ]; then
    printf 'sccache-launcher: sccache failed once, retry succeeded (cache kept) [server=%s].\n' \
      "${SCCACHE_SERVER_UDS:-tcp:${SCCACHE_SERVER_PORT:-4226}}" >&2
    cat "${_err}" >&2
    rm -f "${_err}"
    exit 0
  fi
  if _sccache_own_failure "${_err}"; then
    # Report it before compiling directly: a silent bypass would hide a dead cache.
    printf 'sccache-launcher: sccache failed twice on its own account [server=%s]; compiling directly.\n' \
      "${SCCACHE_SERVER_UDS:-tcp:${SCCACHE_SERVER_PORT:-4226}}" >&2
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
