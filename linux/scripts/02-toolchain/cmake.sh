#!/usr/bin/env bash
set -euo pipefail
# cmake.sh - CMake from Kitware

install_cmake() {
  local version="${CMAKE_VERSION:-4.4.0}"
  local arch="${ARCH:-$(dpkg --print-architecture 2>/dev/null || uname -m)}"
  local asset=""
  local sha256=""
  local url=""
  local tmpdir=""
  local install_root="/opt/cmake-${version}"

  case "${arch}" in
    amd64|x86_64)
      asset="cmake-${version}-linux-x86_64.tar.gz"
      sha256="${CMAKE_AMD64_SHA256:-3864eb649b4466ae126a64bbde1657adad78efbbaa068bf38201de5cf1b5349f}"
      ;;
    arm64|aarch64)
      asset="cmake-${version}-linux-aarch64.tar.gz"
      sha256="${CMAKE_ARM64_SHA256:-e98bb53e0b00a8f672424517d34c05bb9b94fd1c888c89e0b81bc8df51d1a94b}"
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
