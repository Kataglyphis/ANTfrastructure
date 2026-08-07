#!/usr/bin/env bash
set -euo pipefail
# cmake.sh - CMake from Kitware

install_cmake() {
  local version="${CMAKE_VERSION:-4.4.2}"
  local arch="${ARCH:-$(dpkg --print-architecture 2>/dev/null || uname -m)}"
  local asset=""
  local sha256=""
  local url=""
  local tmpdir=""
  local install_root="/opt/cmake-${version}"

  # The hardcoded SHA fallbacks below belong to the DEFAULT version. If someone
  # bumps CMAKE_VERSION without the matching CMAKE_*_SHA256 reaching this
  # process, the fallback SHA is for the OLD tarball and the download would die
  # as a "checksum mismatch" that reads like tampering. Fail with the real
  # cause instead.
  if [ "${version}" != "4.4.2" ] && [ -z "${CMAKE_AMD64_SHA256:-}${CMAKE_ARM64_SHA256:-}" ]; then
    die "CMAKE_VERSION=${version} but no CMAKE_*_SHA256 env set — the built-in SHA fallbacks only match 4.4.2 (update versions.env / pass the SHAs)"
  fi

  case "${arch}" in
    amd64|x86_64)
      asset="cmake-${version}-linux-x86_64.tar.gz"
      sha256="${CMAKE_AMD64_SHA256:-3ada9a3f5d8a85413579bdd0ea6aa8e8da86efdd6d15c91a1afa517f2021956c}"
      ;;
    arm64|aarch64)
      asset="cmake-${version}-linux-aarch64.tar.gz"
      sha256="${CMAKE_ARM64_SHA256:-9ca1aadb4451c5dcbdc67f9b4aff42dab52abbaebd8db9e2900026502dbed671}"
      ;;
    riscv64)
      log "Using distro CMake on riscv64; Kitware does not publish a prebuilt archive for this architecture"
      apt_install cmake
      cmake --version || true
      return 0
      ;;
    *)
      die "Unsupported CMake install architecture: ${arch}"
      ;;
  esac

  url="https://github.com/Kitware/CMake/releases/download/v${version}/${asset}"
  tmpdir="$(mktemp -d)"

  log "Installing pinned CMake ${version} from ${url}"
  download_verified_file "${url}" "${sha256}" "${tmpdir}/${asset}"
  tar -xzf "${tmpdir}/${asset}" -C "${tmpdir}"

  $SUDO rm -rf "${install_root}"
  $SUDO mv "${tmpdir}/${asset%.tar.gz}" "${install_root}"

  for tool in cmake ctest cpack ccmake; do
    [ -e "${install_root}/bin/${tool}" ] || continue
    $SUDO ln -sf "${install_root}/bin/${tool}" "/usr/local/bin/${tool}"
  done

  rm -rf "${tmpdir}"
  cmake --version || true
}
