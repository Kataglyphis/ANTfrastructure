#!/usr/bin/env bash
# sccache's shared S3 level in a BuildKit RUN, sourced by common.sh and compiler-cache.sh, `drain` its last command: docs/build-cache-tiers.md#the-shared-s3-level

# Only these names reach the server; anything else in the secret is ignored.
_SCCACHE_S3_NAMES="SCCACHE_BUCKET SCCACHE_ENDPOINT SCCACHE_REGION SCCACHE_S3_USE_SSL AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY"

_sccache_s3_log() {
  printf '[CACHE] %s\n' "$*" >&2
}

# <url>: 0 when its host:port takes a TCP connection within 2 s; a dead level costs the server its whole startup.
sccache_s3_endpoint_reachable() {
  local rest="${1#*://}" host port
  rest="${rest%%/*}"
  host="${rest%:*}"
  port="${rest##*:}"
  [ "${host}" != "${rest}" ] || port=80
  [ -n "${host}" ] && [ -n "${port}" ] || return 1
  # shellcheck disable=SC2016 # expanded by the inner bash, from its arguments
  timeout 2 bash -c ': >"/dev/tcp/$1/$2"' _ "${host}" "${port}" 2>/dev/null
}

# <array-name>: fills it with NAME=value pairs for the server, or leaves it empty and says why.
sccache_s3_env() {
  local -n _s3_out="$1"
  _s3_out=()
  local file="${SCCACHE_S3_SECRET_FILE:-/run/secrets/sccache_s3}" line name value
  [ -e "${file}" ] || return 0
  if [ ! -r "${file}" ]; then
    _sccache_s3_log "sccache: ${file} is not readable by uid $(id -u) -- no S3 level in this RUN"
    return 0
  fi
  local -A _s3_kv=()
  while IFS= read -r line || [ -n "${line}" ]; do
    case "${line}" in ''|'#'*) continue ;; esac
    name="${line%%=*}"; value="${line#*=}"
    case " ${_SCCACHE_S3_NAMES} " in *" ${name} "*) _s3_kv["${name}"]="${value}" ;; esac
  done < "${file}"
  for name in SCCACHE_BUCKET SCCACHE_ENDPOINT AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; do
    if [ -z "${_s3_kv[${name}]:-}" ]; then
      _sccache_s3_log "sccache: the S3 secret has no ${name} -- no S3 level in this RUN"
      return 0
    fi
  done
  if ! sccache_s3_endpoint_reachable "${_s3_kv[SCCACHE_ENDPOINT]}"; then
    _sccache_s3_log "sccache: the S3 level (${_s3_kv[SCCACHE_ENDPOINT]}) takes no TCP connection within 2 s -- this RUN caches on disk alone"
    return 0
  fi
  for name in "${!_s3_kv[@]}"; do _s3_out+=("${name}=${_s3_kv[${name}]}"); done
  _s3_out+=("SCCACHE_MULTILEVEL_CHAIN=disk,s3")
}

# 0 when this sccache can chain levels: the chain was checked against 0.18's multilevel.rs only.
_sccache_s3_version_ok() {
  local v
  v="$(sccache --version 2>/dev/null | awk '{print $2}')"
  [ -n "${v}" ] || return 1
  [ "$(printf '%s\n' 0.18.0 "${v}" | sort -V | head -n 1)" = 0.18.0 ] && return 0
  return 1
}

# Starts the server, with the S3 level when the RUN has its secret; the key stays out of the build's own environment.
sccache_start_server() {
  local -a s3=()
  # Without a socket a running server cannot be told apart, and a second start must not replace it.
  if [ -z "${SCCACHE_SERVER_UDS:-}" ] || ! _sccache_s3_version_ok; then
    sccache --start-server >/dev/null 2>&1 || true
    return 0
  fi
  if [ -S "${SCCACHE_SERVER_UDS}" ] && sccache --show-stats >/dev/null 2>&1; then
    return 0
  fi
  sccache_s3_env s3
  if [ "${#s3[@]}" -gt 0 ]; then
    local out
    # The client can exit 0 after giving up on a server that is still checking its levels.
    if out="$(env "${s3[@]}" sccache --start-server 2>&1)" && ! grep -qE 'Timed out waiting for server startup|Server startup failed' <<<"${out}"; then
      _sccache_s3_log "sccache levels: disk ${SCCACHE_DIR:-} -> s3 $(printf '%s\n' "${s3[@]}" | sed -n 's/^SCCACHE_ENDPOINT=//p')"
      return 0
    fi
    # One level that fails its startup check stops the whole server, so a refused key would leave every compile uncached.
    _sccache_s3_log "sccache: the server did not start with the S3 level ($(printf '%s\n' "${out}" | grep -m1 -E 'error|Timed out' || echo 'no reason given')) -- starting it on disk alone"
    sccache --stop-server >/dev/null 2>&1 || true
  fi
  sccache --start-server >/dev/null 2>&1 || true
}

# Echoes the uploads still pending (the most any slower level lags level 0), or nothing without a chain.
_sccache_s3_pending() {
  sccache --show-stats --stats-format json 2>/dev/null | python3 -c '
import json, sys
levels = (json.load(sys.stdin).get("stats") or {}).get("multi_level") or []
if len(levels) >= 2:
    l0 = levels[0]["writes"]
    print(max(l0 - l["writes"] - l["write_failures"] for l in levels[1:]),
          "; ".join("%s: %d written, %d failed" % (l["name"], l["writes"], l["write_failures"]) for l in levels[1:]),
          "of", l0)
' 2>/dev/null
}

# [timeout-s]: the RUN's end kills the server and drops its background uploads, so wait for them first.
sccache_s3_drain() {
  local limit="${1:-${SCCACHE_S3_DRAIN_TIMEOUT:-600}}" start now report=-30 pending tally
  : "${SCCACHE_SERVER_UDS:=/tmp/sccache-$(id -u).sock}"
  export SCCACHE_SERVER_UDS
  # Asking a server that is not there would start one.
  [ -S "${SCCACHE_SERVER_UDS}" ] && command -v sccache >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || return 0
  start="$(date +%s)"
  while :; do
    read -r pending tally < <(_sccache_s3_pending) || true
    [ -n "${pending:-}" ] || return 0
    now=$(( $(date +%s) - start ))
    if [ "${pending}" -le 0 ]; then
      printf 'sccache-drain| every upload done after %d s (%s)\n' "${now}" "${tally}" >&2
      return 0
    fi
    if [ "${now}" -ge "${limit}" ]; then
      _sccache_s3_log "sccache: ${pending} upload(s) still pending after ${limit} s (${tally}); the RUN's end drops them, and a later build uploads them again"
      return 0
    fi
    if [ $(( now - report )) -ge 30 ]; then
      printf 'sccache-drain| %d upload(s) pending after %d s (%s)\n' "${pending}" "${now}" "${tally}" >&2
      report="${now}"
    fi
    sleep 2
  done
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-}" in
    drain) sccache_s3_drain "${2:-}"; exit 0 ;;
    *) printf 'usage: %s drain [timeout-s]\n' "${0##*/}" >&2; exit 2 ;;
  esac
fi
