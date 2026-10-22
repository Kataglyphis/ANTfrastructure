#!/usr/bin/env bash
# Export in the compiling shell; see docs/build-cache-tiers.md#the-server-address-must-be-exported-where-the-compiles-run.
sccache_configure_server_address() {
  if [ -n "${SCCACHE_SERVER_UDS:-}" ] || [ -n "${SCCACHE_SERVER_PORT:-}" ]; then
    return 0
  fi
  local _scv _scv_maj _scv_rest _scv_min _scp_off
  _scv="$(sccache --version 2>/dev/null | awk '{print $2}')"
  _scv_maj="${_scv%%.*}"; _scv_rest="${_scv#*.}"; _scv_min="${_scv_rest%%.*}"
  if [ "${_scv_maj:-0}" -ge 1 ] 2>/dev/null || [ "${_scv_min:-0}" -ge 14 ] 2>/dev/null; then
    SCCACHE_SERVER_UDS="/tmp/sccache-$(id -u).sock"
    export SCCACHE_SERVER_UDS
  else
    _scp_off="$(printf '%s' "${HOSTNAME:-$$}" | cksum | awk '{print $1 % 20000}')"
    SCCACHE_SERVER_PORT="$(( 20000 + _scp_off ))"
    export SCCACHE_SERVER_PORT
  fi
}
