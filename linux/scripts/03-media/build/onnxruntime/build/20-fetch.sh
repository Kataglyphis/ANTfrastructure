#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

parse_common_args "$@"
detect_jobs

# ----------------------------
# Clone repo and submodules
# ----------------------------
if [ ! -d "${ORT_SRC_DIR}" ]; then
  info "Cloning ONNX Runtime ${ORT_VERSION} into ${ORT_SRC_DIR}"
  retry 3 10 "ONNX Runtime git clone" git clone --branch "${ORT_VERSION}" --depth 1 "${ORT_REPO}" "${ORT_SRC_DIR}"
fi

cd "${ORT_SRC_DIR}"

retry 3 10 "ONNX Runtime submodule sync" git submodule sync --recursive || true
retry 3 10 "ONNX Runtime submodule update" git submodule update --init --recursive

# ----------------------------
# Clone GenAI repo if enabled
# ----------------------------
if [[ "${BUILD_GENAI}" == "true" ]]; then
  if [ ! -d "${GENAI_SRC_DIR}" ]; then
    info "Cloning ONNX Runtime GenAI ${GENAI_VERSION} into ${GENAI_SRC_DIR}"
    retry 3 10 "ONNX Runtime GenAI git clone" git clone --branch "${GENAI_VERSION}" --depth 1 "${GENAI_REPO}" "${GENAI_SRC_DIR}"
  else
    info "GenAI source directory exists at ${GENAI_SRC_DIR}"
  fi
  
  cd "${GENAI_SRC_DIR}"
  git submodule sync --recursive || true
  git submodule update --init --recursive
  cd "${ORT_SRC_DIR}"
fi

# ----------------------------
# Python env (uv venv) to avoid PEP 668 issues
# ----------------------------
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

# ----------------------------
# Setup emsdk (if present in repo)
# ----------------------------
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
