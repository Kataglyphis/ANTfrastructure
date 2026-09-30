#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

parse_common_args "$@"
detect_jobs

# System packages
if [ "${SKIP_DEP_INSTALL}" != "true" ]; then
  info "Installing OS packages (apt-get)..."
  export DEBIAN_FRONTEND=noninteractive
  if command -v cross_prepare_foreign_arch >/dev/null 2>&1 && cross_build_enabled; then
    cross_prepare_foreign_arch
  fi
  apt-get update -qq

  install_host_packages \
    git ca-certificates curl wget build-essential pkg-config \
    cmake ninja-build zlib1g-dev \
    protobuf-compiler gnupg lsb-release libssl-dev

  install_target_packages libprotobuf-dev

  # Node comes from the base image's checksum-pinned install; piping NodeSource's script into root bash is banned.
  ARCH="$(arch_oci 2>/dev/null || dpkg --print-architecture 2>/dev/null || uname -m)"
  if command -v node >/dev/null 2>&1; then
    info "node already present ($(node -v 2>/dev/null || echo '?')) — using the sha-pinned base-image install"
  elif [ "$ARCH" = "riscv64" ]; then
    info "RISC-V detected: Installing Node.js from default apt repo"
    apt-get install -y --no-install-recommends nodejs npm || {
      warn "npm not found after installing nodejs"
    }
  else
    err "node missing on ${ARCH} — the base image should ship the pinned Node ${NODE_VERSION:-26.x}; refusing the unpinned NodeSource fallback (supply-chain policy)"
  fi
else
  info "Skipping apt deps install (SKIP_DEP_INSTALL=true)"
fi

# No curl|sh fallback: npm must come from the same pinned provisioning as node.
if ! command -v npm >/dev/null 2>&1; then
  err "npm not available alongside node — fix the node provisioning (base image ships npm with the pinned Node; riscv64 apt installs the npm package)"
fi

info "node: $(node -v || true), npm: $(npm -v || true)"
