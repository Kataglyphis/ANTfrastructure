#!/usr/bin/env bash
# A marker alone cannot authenticate the shared pool's source, configured flavors or compiled bytes.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
verify_only=0
if [ "${1:-}" = --verify-only ]; then verify_only=1; shift; fi
source "${here}/lib/common.sh"
parse_common_args "$@"
case "${ORT_WEB_REQUIRED:-0}" in 0|1) ;; *) printf '%s\n' 'ORT_WEB_REQUIRED must be 0 or 1' >&2; exit 2 ;; esac
revision="$(git -C "${ORT_SRC_DIR}" rev-parse --verify HEAD)"
proof=(python3 "${here}/lib/ort-webgpu-wasm-proof.py")
options=(--source-ref "${ORT_VERSION}" --source-revision "${revision}" --config "${WASM_CONFIG}" --flavors "${ORT_WASM_WEBGPU_FLAVORS}")
if [ "${verify_only}" = 1 ]; then
  "${proof[@]}" verify --prefix "${WASM_OUTPUT_DIR}" "${options[@]}"
  exit 0
fi
shared="${ORT_WEB_SHARED_CACHE:-/var/cache/onnxruntime-web-shared}"
mkdir -p "${shared}" "${WASM_OUTPUT_DIR}"

if "${proof[@]}" verify-cache --prefix "${shared}" "${options[@]}"; then
  "${proof[@]}" copy-cache --prefix "${shared}" --destination "${WASM_OUTPUT_DIR}" "${options[@]}"
else
  "${proof[@]}" reset --prefix "${shared}" "${options[@]}"
  "${proof[@]}" reset --prefix "${WASM_OUTPUT_DIR}" "${options[@]}"
  if bash "${here}/build-onnxruntime.sh" --step wasm "$@"; then
    if "${proof[@]}" verify --prefix "${WASM_OUTPUT_DIR}" "${options[@]}"; then
      cp -a "${WASM_OUTPUT_DIR}/." "${shared}/"
      "${proof[@]}" seal-cache --prefix "${shared}" "${options[@]}"
      "${proof[@]}" verify-cache --prefix "${shared}" "${options[@]}"
    elif [ "${ORT_WEB_REQUIRED:-0}" = 1 ]; then
      exit 1
    else
      warn "Optional WASM output lacks a complete proof; shared cache remains unstamped"
    fi
  else
    status=$?
    if [ "${ORT_WEB_REQUIRED:-0}" = 1 ]; then exit "${status}"; fi
    warn "Optional WASM build failed; shared cache remains unstamped"
  fi
fi
