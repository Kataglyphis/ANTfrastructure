#!/usr/bin/env bash
set -euo pipefail
# cmake.sh - CMake from Kitware

install_cmake() {
  local version="${CMAKE_VERSION:-4.3.3}"
  local arch="${ARCH:-$(dpkg --print-architecture 2>/dev/null || uname -m)}"
  local asset=""
  local sha256=""
  local url=""
  local tmpdir=""
  local install_root="/opt/cmake-${version}"

  case "${arch}" in
    amd64|x86_64)
      asset="cmake-${version}-linux-x86_64.tar.gz"
      sha256="${CMAKE_AMD64_SHA256:-927b2368a946c37269c3a66225ab00544e756459cdd0b5d0da438694fb9ff802}"
      ;;
    arm64|aarch64)
      asset="cmake-${version}-linux-aarch64.tar.gz"
      sha256="${CMAKE_ARM64_SHA256:-9ea38356dbd3e32e51029a3e09a0f2f8e117ef4fbcaad7a21ffb36409bbd5cb4}"
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
