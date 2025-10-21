#!/usr/bin/env bash
# common.sh - shared helpers and configuration

export DEBIAN_FRONTEND=noninteractive
export TZ=Etc/UTC

# Defaults (overridden by CLI or ENV)
LLVM_WANTED=${LLVM_WANTED:-21}
CLANG_WANTED=${CLANG_WANTED:-21}
GCC_WANTED=${GCC_WANTED:-14}
VULKAN_VERSION_DEFAULT=${VULKAN_VERSION_DEFAULT:-1.4.328.1}

APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
APT_FLAGS=(-yq --no-install-recommends "${APT_OPTS[@]}")

SUDO=""
APT_UPDATED=""

log() { printf '[INFO] %s\n' "$*"; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

require_sudo() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    command -v sudo >/dev/null 2>&1 || die "This script requires sudo or root."
    SUDO="sudo"
  else
    SUDO=""
  fi
}

detect_system() {
  # Prefer Docker's TARGETARCH if present; map to uname-style
  local mapped=""
  if [ -n "${TARGETARCH:-}" ]; then
    case "$TARGETARCH" in
      amd64)  mapped="x86_64" ;;
      arm64)  mapped="aarch64" ;;
      *)      mapped="$TARGETARCH" ;;
    esac
  fi
  ARCH="${mapped:-$(uname -m)}"

  if command -v lsb_release >/dev/null 2>&1; then
    DISTRO="$(lsb_release -cs)"
  elif [ -r /etc/os-release ]; then
    . /etc/os-release
    DISTRO="${UBUNTU_CODENAME:-${VERSION_CODENAME:-jammy}}"
  else
    DISTRO="jammy"
  fi
  export ARCH DISTRO
  log "Detected arch=${ARCH} distro=${DISTRO}"
}

apt_update_once() {
  if [ -z "${APT_UPDATED}" ]; then
    $SUDO apt-get update -y
    APT_UPDATED=1
  fi
}

apt_install() {
  apt_update_once
  $SUDO apt-get install "${APT_FLAGS[@]}" "$@"
}