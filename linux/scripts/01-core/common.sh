#!/usr/bin/env bash
# common.sh - shared helpers and configuration

_COMMON_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source canonical version defaults (single source of truth).
# Variables already set in the environment take precedence over versions.env.
set -a
# shellcheck disable=SC1090,SC1091
[ -f "${_COMMON_SH_DIR}/versions.env" ] && source "${_COMMON_SH_DIR}/versions.env"
set +a

# Side-effect free helpers
# shellcheck disable=SC1090,SC1091
[ -f "${_COMMON_SH_DIR}/logging.sh" ] && source "${_COMMON_SH_DIR}/logging.sh"
# shellcheck disable=SC1090,SC1091
[ -f "${_COMMON_SH_DIR}/platform.sh" ] && source "${_COMMON_SH_DIR}/platform.sh"
# shellcheck disable=SC1090,SC1091
[ -f "${_COMMON_SH_DIR}/ubuntu-mirror.sh" ] && source "${_COMMON_SH_DIR}/ubuntu-mirror.sh"
# shellcheck disable=SC1090,SC1091
[ -f "${_COMMON_SH_DIR}/downloads.sh" ] && source "${_COMMON_SH_DIR}/downloads.sh"
# shellcheck disable=SC1090,SC1091
[ -f "${_COMMON_SH_DIR}/parallelism.sh" ] && source "${_COMMON_SH_DIR}/parallelism.sh"

export DEBIAN_FRONTEND=noninteractive
export TZ=Etc/UTC

# Derived defaults (use the canonical values from versions.env as fallbacks)
if [ -z "${LLVM_WANTED:-}" ]; then
  LLVM_WANTED="${LLVM_RELEASE}"
  LLVM_WANTED="$(version_major "${LLVM_WANTED}")"
fi

if [ -z "${CLANG_WANTED:-}" ]; then
  CLANG_WANTED="${LLVM_WANTED}"
fi

if [ -z "${GCC_WANTED:-}" ]; then
  GCC_WANTED="${GCC_VERSION}"
  GCC_WANTED="$(version_major "${GCC_WANTED}")"
fi

if [ -z "${PYTHON_MAJOR_MINOR:-}" ] && [ -n "${PYTHON_VERSION:-}" ]; then
  PYTHON_MAJOR_MINOR="$(version_major_minor "${PYTHON_VERSION}")"
fi

VULKAN_VERSION_DEFAULT=${VULKAN_VERSION_DEFAULT:-${VULKAN_VERSION}}

# ---------------------------------------------------------------------------
# ensure_target_arch
#
# Normalizes TARGET_ARCH from TARGETARCH when TARGET_ARCH is unset.
# Print the resolved value and export it.
# ---------------------------------------------------------------------------
ensure_target_arch() {
  TARGET_ARCH="$(canonical_target_arch "${TARGET_ARCH:-}")"
  export TARGET_ARCH
  echo "TARGET_ARCH=${TARGET_ARCH}"
}

APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
APT_FLAGS=(-qq --no-install-recommends "${APT_OPTS[@]}")

SUDO=""
APT_UPDATED=""

tool_version() {
  local cmd="$1"
  shift || true
  if command -v "$cmd" >/dev/null 2>&1; then
    "$cmd" "$@" || true
  fi
}

require_sudo() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    command -v sudo >/dev/null 2>&1 || die "This script requires sudo or root."
    SUDO="sudo"
  else
    SUDO=""
  fi
}

detect_system() {
  local target_arch build_arch
  target_arch="$(arch_oci)"
  build_arch="$(build_arch_oci)"
  ARCH="$(arch_uname_name_for "${target_arch}")"
  HOST_ARCH="$(arch_uname_name_for "${build_arch}")"

  if command -v lsb_release >/dev/null 2>&1; then
    DISTRO="$(lsb_release -cs)"
  elif [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    DISTRO="${UBUNTU_CODENAME:-${VERSION_CODENAME:-jammy}}"
  else
    DISTRO="jammy"
  fi
  export ARCH HOST_ARCH DISTRO
  log "Detected arch=${ARCH} host_arch=${HOST_ARCH} distro=${DISTRO}"
}

apt_update_once() {
  if [ -z "${APT_UPDATED}" ]; then
    $SUDO apt-get update -qq
    APT_UPDATED=1
  fi
}

apt_install() {
  apt_update_once
  $SUDO apt-get install -y "${APT_FLAGS[@]}" "$@"
}

apt_has_package() {
  local pkg="$1"
  apt-cache show "$pkg" >/dev/null 2>&1
}

apt_install_available() {
  local pkg
  local -a pkgs=()

  for pkg in "$@"; do
    if apt_has_package "$pkg"; then
      pkgs+=("$pkg")
    else
      log "Skipping missing package: ${pkg}"
    fi
  done

  if [ "${#pkgs[@]}" -gt 0 ]; then
    apt_install "${pkgs[@]}"
  fi
}

append_flag_if_missing() {
  local var_name="$1"
  local flag="$2"
  local current="${!var_name:-}"

  case " ${current} " in
    *" ${flag} "*) return 0 ;;
  esac

  export "${var_name}=${current:+${current} }${flag}"
}
