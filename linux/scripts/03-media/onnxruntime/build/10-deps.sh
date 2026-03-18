#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

parse_common_args "$@"
detect_jobs

# ----------------------------
# Install system deps (Debian/Ubuntu)
# ----------------------------
if [ "${SKIP_DEP_INSTALL}" != "true" ]; then
  info "Installing OS packages (apt-get)..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq

  # Base packages
  apt-get install -y --no-install-recommends \
    git ca-certificates curl wget build-essential pkg-config \
    python3 python3-dev python3-venv cmake ninja-build zlib1g-dev \
    protobuf-compiler libprotobuf-dev gnupg lsb-release libssl-dev

  # Node.js: different for RISC-V vs. other architectures
  ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)
  if [ "$ARCH" = "riscv64" ]; then
    info "RISC-V detected: Installing Node.js from default apt repo"
    apt-get install -y --no-install-recommends nodejs npm || {
      warn "npm not found after installing nodejs"
    }
  else
    info "Non-RISC-V architecture: Installing Node.js from NodeSource"
    if [ ! -f /tmp/nodesource/.setup_done ]; then
      curl -sL https://deb.nodesource.com/setup_24.x | bash -
      mkdir -p /tmp/nodesource
      touch /tmp/nodesource/.setup_done
    fi
    apt-get update -qq
    apt-get install -y --no-install-recommends nodejs
  fi
else
  info "Skipping apt deps install (SKIP_DEP_INSTALL=true)"
fi

# Verify npm exists; if not, install npm via official npm installer
if ! command -v npm >/dev/null 2>&1; then
  warn "npm not found after installing nodejs. Installing npm via official installer..."
  curl -qL https://www.npmjs.com/install.sh | sh
  command -v npm >/dev/null 2>&1 || err "npm install fallback failed — npm not available. Consider installing node via NodeSource or nvm."
fi

info "node: $(node -v || true), npm: $(npm -v || true)"
