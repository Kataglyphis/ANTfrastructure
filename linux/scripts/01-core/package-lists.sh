#!/usr/bin/env bash

# package-lists.sh - shared apt package lists for image/bootstrap scripts

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
  for pkg in "$@"; do
    if apt_package_exists "${pkg}"; then
      append_unique_packages "${array_name}" "${pkg}"
    fi
  done
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

  append_unique_packages "${array_name}" \
    nano tmux vim \
    sudo curl ca-certificates gnupg wget xz-utils libssl-dev git \
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
