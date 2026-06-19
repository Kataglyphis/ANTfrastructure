#!/usr/bin/env bash
# cmake.sh - CMake from Kitware

install_cmake() {
  local version="${CMAKE_VERSION:-4.3.2}"
  local arch="${ARCH:-$(dpkg --print-architecture 2>/dev/null || uname -m)}"
  local asset=""
  local sha256=""
  local url=""
  local tmpdir=""
  local install_root="/opt/cmake-${version}"

  case "${arch}" in
    amd64|x86_64)
      asset="cmake-${version}-linux-x86_64.tar.gz"
      sha256="${CMAKE_AMD64_SHA256:-791ae3604841ca03cb3889a3ad89165346e4b180ae3448efd4b0caa9ef46d245}"
      ;;
    arm64|aarch64)
      asset="cmake-${version}-linux-aarch64.tar.gz"
      sha256="${CMAKE_ARM64_SHA256:-377079ab739f5765176f427609d9a2015b756ea20d5cba908d279c3731a2f481}"
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
