#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

_fetch_clone_if_missing() {
  local label="$1" version="$2" repository="$3" directory="$4" existing_message="${5:-}"
  if [ -d "$directory" ]; then
    [ -z "$existing_message" ] || info "$existing_message"
    return 0
  fi
  info "Cloning $label $version into $directory"
  retry 3 10 "$label git clone" git clone --branch "$version" --depth 1 "$repository" "$directory"
}

parse_common_args "$@"
detect_jobs

# ONNX Runtime source
_fetch_clone_if_missing "ONNX Runtime" "${ORT_VERSION}" "${ORT_REPO}" "${ORT_SRC_DIR}"

cd "${ORT_SRC_DIR}"

retry 3 10 "ONNX Runtime submodule sync" git submodule sync --recursive || true
retry 3 10 "ONNX Runtime submodule update" git submodule update --init --recursive

# GenAI source
if [[ "${BUILD_GENAI}" == "true" ]]; then
  _fetch_clone_if_missing "ONNX Runtime GenAI" "${GENAI_VERSION}" "${GENAI_REPO}" "${GENAI_SRC_DIR}" \
    "GenAI source directory exists at ${GENAI_SRC_DIR}"

  cd "${GENAI_SRC_DIR}"
  git submodule sync --recursive || true
  git submodule update --init --recursive
  cd "${ORT_SRC_DIR}"
fi

# Python requirements go into the uv venv because the system Python is PEP 668 managed
if [ "${USE_UV_VENV}" = "true" ]; then
  require_cmd uv

  info "Using existing uv venv (expected at /opt/python/.venv)"

  if [ -f "${ORT_SRC_DIR}/requirements.txt" ]; then
    info "Installing ONNX Runtime Python requirements via uv"
    uv pip install -r "${ORT_SRC_DIR}/requirements.txt"
  else
    warn "No requirements.txt found at ${ORT_SRC_DIR}/requirements.txt; skipping uv pip install"
  fi
fi

# emsdk
if command -v build_arch_oci >/dev/null 2>&1 && [ "$(build_arch_oci)" != "amd64" ]; then
  info "Skipping emsdk setup on non-amd64 build host"
  info "Fetch step complete (ORT_VERSION=${ORT_VERSION})"
  exit 0
fi

EMSDK_DIR="${ORT_SRC_DIR}/cmake/external/emsdk"
if [ -d "${EMSDK_DIR}" ]; then
  info "Setting up emsdk at ${EMSDK_DIR}"
  cd "${EMSDK_DIR}"
  if [ -f "emsdk_version.txt" ]; then
    EMSDK_VERSION="$(cat emsdk_version.txt)"
    ./emsdk install "${EMSDK_VERSION}" || ./emsdk install "${EMSDK_VERSION}"
    ./emsdk activate "${EMSDK_VERSION}"
  else
    ./emsdk install latest || true
    ./emsdk activate latest || true
  fi
  # shellcheck disable=SC1091
  source ./emsdk_env.sh || true
  cd "${ORT_SRC_DIR}"
else
  warn "emsdk directory not found at ${EMSDK_DIR}; WASM builds will fail without emsdk."
fi

info "Fetch step complete (ORT_VERSION=${ORT_VERSION})"
