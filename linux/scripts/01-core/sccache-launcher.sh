#!/usr/bin/env bash
# sccache's own failures never kill the build; bash, since dash drops hyphenated env names. docs/build-cache-tiers.md#sccache-failure-classes-the-launcher-must-bypass

# Host-wide compile slots on fd 9, shared by every build through the sccache cache mount: docs/build-parallelism-memory-tuning.md#the-compile-governor
_governor_acquire() {
  : "${KATAGLYPHIS_COMPILE_GOVERNOR:=on}" "${KATAGLYPHIS_COMPILE_GOVERNOR_ADMIT_MB:=3072}" "${KATAGLYPHIS_COMPILE_GOVERNOR_MAX_WAIT:=1800}" "${KATAGLYPHIS_COMPILE_GOVERNOR_POLL:=0.2}"
  [ "${KATAGLYPHIS_COMPILE_GOVERNOR}" != off ] || return 0
  command -v flock >/dev/null 2>&1 || return 0
  _gov_dir="${KATAGLYPHIS_COMPILE_GOVERNOR_DIR:-${SCCACHE_DIR:-/var/cache/sccache}/.compile-slots}"
  mkdir -p "${_gov_dir}" 2>/dev/null || return 0
  [ -w "${_gov_dir}" ] || return 0
  _gov_slots="${KATAGLYPHIS_COMPILE_GOVERNOR_SLOTS:-$(nproc 2>/dev/null || echo 1)}"
  _gov_start="$(date +%s)"
  while :; do
    _gov_i=0
    while [ "${_gov_i}" -lt "${_gov_slots}" ]; do
      _gov_slot="${_gov_dir}/slot.${_gov_i}"
      [ -e "${_gov_slot}" ] || ( umask 0; : >>"${_gov_slot}" ) 2>/dev/null
      # Read-only, since flock needs no write access across build uids; `command` keeps a failed open from ending dash, and no 2> here, which would stay on the shell.
      if [ -r "${_gov_slot}" ] && command exec 9<"${_gov_slot}" && flock -n 9; then
        # Slot 0 always admits, so a lone build never waits on memory others hold.
        [ "${_gov_i}" -eq 0 ] && return 0
        _gov_avail="$(awk '/^MemAvailable:/ {printf "%d", $2 / 1024; exit}' "${KATAGLYPHIS_COMPILE_GOVERNOR_MEMINFO:-/proc/meminfo}" 2>/dev/null)"
        [ "${_gov_avail:-0}" -ge "${KATAGLYPHIS_COMPILE_GOVERNOR_ADMIT_MB}" ] 2>/dev/null && return 0
      fi
      exec 9>&-
      _gov_i=$((_gov_i + 1))
    done
    if [ $(( $(date +%s) - _gov_start )) -ge "${KATAGLYPHIS_COMPILE_GOVERNOR_MAX_WAIT}" ]; then
      printf 'sccache-launcher: no compile slot in %s after %s s; compiling ungoverned.\n' "${_gov_dir}" "${KATAGLYPHIS_COMPILE_GOVERNOR_MAX_WAIT}" >&2
      return 0
    fi
    sleep "${KATAGLYPHIS_COMPILE_GOVERNOR_POLL}"
  done
}
_governor_acquire

_err="$(mktemp /tmp/sccache-launcher.XXXXXX 2>/dev/null)" || _err=""

if [ -z "${_err}" ]; then
  # Without a temp file a failure cannot be classified, so behave like plain sccache; a server it autostarts must not keep the slot.
  exec sccache "$@" 9>&-
fi

# fd 9 stays with this process: a sccache server the client autostarts would otherwise hold the slot for good.
sccache "$@" 2>"${_err}" 9>&-
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
  sccache "$@" 2>"${_err}" 9>&-
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
