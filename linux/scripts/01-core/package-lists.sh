#!/usr/bin/env bash

# package-lists.sh - shared apt package lists for image/bootstrap scripts

_PACKAGE_LISTS_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Thin wrapper around apt_has_package (canonical, in common.sh). Exists so
# callers that source package-lists.sh without common.sh still get a working
# probe via the fallback body below.
apt_package_exists() {
  if declare -F apt_has_package >/dev/null 2>&1; then
    apt_has_package "$@"
    return
  fi
  local pkg="$1"
  apt-cache show "${pkg}" >/dev/null 2>&1
}

append_unique_packages() {
  local array_name="$1"
  shift

  local -n packages_ref="${array_name}"
  local -A _seen=()
  local pkg

  for pkg in "${packages_ref[@]}"; do
    _seen["${pkg}"]=1
  done

  for pkg in "$@"; do
    if [ -z "${_seen["${pkg}"]:-}" ]; then
      _seen["${pkg}"]=1
      packages_ref+=("${pkg}")
    fi
  done
}

append_available_packages() {
  local array_name="$1"
  shift

  local pkg
  local -a _absent=()
  for pkg in "$@"; do
    if apt_package_exists "${pkg}"; then
      append_unique_packages "${array_name}" "${pkg}"
    else
      _absent+=("${pkg}")
    fi
  done

  # Never drop silently: an archive/mirror hiccup here used to erase
  # clang/lld/valgrind from the base image with no trace in the build log.
  # Keep this one-liner greppable. warn comes from logging.sh; fall back to
  # plain stderr for callers that source this file without the framework
  # (same contingency as apt_package_exists above).
  if [ "${#_absent[@]}" -gt 0 ]; then
    if declare -F warn >/dev/null 2>&1; then
      warn "append_available_packages: requested-but-absent packages dropped: ${_absent[*]}"
    else
      echo "WARNING: append_available_packages: requested-but-absent packages dropped: ${_absent[*]}" >&2
    fi
  fi
}

packaging_prerequisite_packages() {
  local array_name="$1"

  append_unique_packages "${array_name}" \
    ca-certificates curl wget xz-utils \
    dpkg

  append_available_packages "${array_name}" \
    libfuse3-3 \
    flatpak flatpak-builder \
    elfutils \
    dbus-user-session \
    build-essential appstream apt-utils

  if apt_package_exists libfuse2; then
    append_unique_packages "${array_name}" libfuse2
  elif apt_package_exists libfuse2t64; then
    append_unique_packages "${array_name}" libfuse2t64
  fi
}

base_image_os_packages() {
  local arch="$1"
  local array_name="$2"
  local _cdp _pkg
  local -a _cpython_dev=()

  # STRUCTURAL host/target CPython dev-package parity (backlog TS3): the dev
  # packages CPython's stdlib extensions link against come from the shared
  # cpython-dev-packages.sh table instead of literals here — the same table
  # drives the cross-target install and the extension asserts in
  # 02-toolchain/python/build_python.sh plus the staged-artifact asserts in
  # 06-packaging/smoke-toolchain.sh. Before this, host closure for several of
  # them rested on TRANSITIVE pulls from the GUI dev packages below (the
  # 2026-08-09 libsqlite3-dev incident class).
  if ! declare -F cpython_ext_dev_packages >/dev/null 2>&1; then
    for _cdp in "${_PACKAGE_LISTS_SH_DIR}/cpython-dev-packages.sh" \
                /opt/scripts/core/cpython-dev-packages.sh; do
      if [ -f "${_cdp}" ]; then
        # shellcheck disable=SC1090,SC1091
        source "${_cdp}"
        break
      fi
    done
  fi
  if ! declare -F cpython_ext_dev_packages >/dev/null 2>&1; then
    echo "ERROR: cpython-dev-packages.sh not found - the base image would silently lose the CPython extension dev packages" >&2
    return 1
  fi
  while IFS= read -r _pkg; do _cpython_dev+=("${_pkg}"); done < <(cpython_ext_dev_packages)
  append_unique_packages "${array_name}" "${_cpython_dev[@]}"

  append_unique_packages "${array_name}" \
    nano tmux vim \
    sudo curl ca-certificates gnupg wget xz-utils git \
    build-essential ninja-build make sccache ccache \
    pkg-config lsb-release software-properties-common \
    meson python3 python3-venv python3-pip \
    patchelf unzip zip \
    doxygen iwyu graphviz gcovr \
    libxrandr-dev libxinerama-dev libxcursor-dev libxi-dev \
    libglu1-mesa-dev freeglut3-dev mesa-common-dev mesa-utils \
    wayland-protocols libwayland-dev libxkbcommon-dev \
    libglx-mesa0 libosmesa6-dev \
    libgtk-3-dev libglib2.0-dev libgdk-pixbuf-2.0-dev libatk1.0-dev \
    libpango1.0-dev libx11-dev libx11-xcb-dev \
    libasound2-dev libpulse-dev libdbus-1-dev \
    file dpkg-dev fakeroot binutils

  if [ "${arch}" != "riscv64" ]; then
    if apt_package_exists libc++-18-dev && apt_package_exists libc++abi-18-dev; then
      append_unique_packages "${array_name}" libc++-18-dev libc++abi-18-dev
    elif apt_package_exists libc++-dev && apt_package_exists libc++abi-dev; then
      append_unique_packages "${array_name}" libc++-dev libc++abi-dev
    fi

    append_available_packages "${array_name}" \
      clang clang-format clang-tidy lld llvm llvm-dev libclang-dev libclang-rt-dev lldb valgrind
  fi

  append_available_packages "${array_name}" linux-tools-common
}
