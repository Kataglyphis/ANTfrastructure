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

# --- Build parallelism helpers -------------------------------------------------
# Many build systems default to using all host CPUs. In containers this can
# oversubscribe when CPU quotas are applied. These helpers detect CPU quotas
# (cgroup v2/v1) and apply optional user caps.

_cgroup_cpu_quota_cores() {
  local quota=""
  local period=""

  # cgroup v2
  if [ -r /sys/fs/cgroup/cpu.max ]; then
    # format: "max <period>" or "<quota> <period>"
    read -r quota period < /sys/fs/cgroup/cpu.max || true
    if [ -n "${quota}" ] && [ "${quota}" != "max" ] && [ -n "${period}" ] && [ "${period}" -gt 0 ] 2>/dev/null; then
      echo $(( (quota + period - 1) / period ))
      return 0
    fi
  fi

  # cgroup v1
  if [ -r /sys/fs/cgroup/cpu/cpu.cfs_quota_us ] && [ -r /sys/fs/cgroup/cpu/cpu.cfs_period_us ]; then
    quota="$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us 2>/dev/null || echo "")"
    period="$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us 2>/dev/null || echo "")"
    if [ -n "${quota}" ] && [ -n "${period}" ] && [ "${quota}" -gt 0 ] 2>/dev/null && [ "${period}" -gt 0 ] 2>/dev/null; then
      echo $(( (quota + period - 1) / period ))
      return 0
    fi
  fi

  echo ""
}

detect_available_cores() {
  local cores
  cores="$(nproc --all 2>/dev/null || nproc 2>/dev/null || echo 1)"
  [ "${cores}" -lt 1 ] 2>/dev/null && cores=1

  local quota_cores
  quota_cores="$(_cgroup_cpu_quota_cores)"
  if [ -n "${quota_cores}" ] && [ "${quota_cores}" -gt 0 ] 2>/dev/null; then
    if [ "${quota_cores}" -lt "${cores}" ] 2>/dev/null; then
      cores="${quota_cores}"
    fi
  fi

  [ "${cores}" -lt 1 ] 2>/dev/null && cores=1
  echo "${cores}"
}

compute_jobs() {
  # Usage: compute_jobs [requested]
  local requested="${1:-}"
  local cores
  cores="$(detect_available_cores)"

  local jobs="${cores}"
  if [ -n "${requested}" ]; then
    jobs="${requested}"
  fi

  # Cap to detected available cores
  if [ "${jobs}" -gt "${cores}" ] 2>/dev/null; then
    jobs="${cores}"
  fi

  [ "${jobs}" -lt 1 ] 2>/dev/null && jobs=1
  echo "${jobs}"
}