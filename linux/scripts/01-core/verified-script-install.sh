#!/usr/bin/env bash

# Callbacks retain each installer's mismatch diagnostics and cleanup order.
verified_script_install() {
  local _vsi_file="$1" _vsi_url="$2" _vsi_digest="$3" _vsi_failure="$4"
  shift 4
  curl --proto '=https' --tlsv1.2 -fsSL --retry 3 -o "${_vsi_file}" "${_vsi_url}"
  if [ -n "${_vsi_digest}" ]; then
    printf '%s  %s\n' "${_vsi_digest}" "${_vsi_file}" | sha256sum -c - || "${_vsi_failure}" "${_vsi_file}"
  fi
  sh "${_vsi_file}" "$@"
  rm -f "${_vsi_file}"
}
