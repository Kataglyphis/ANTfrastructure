#!/usr/bin/env bash
set -euo pipefail

# swap-native-gcc.sh
#
# Swaps the amd64-hosted GCC at /opt/gcc-${GCC_VERSION} with the target-native
# GCC (cross-compiled from source during the compiler image build, stored at
# /opt/gcc-${GCC_VERSION}-native-${TARGET_ARCH}/).
#
# Performs ELF architecture assertions before and after the swap, creates
# symlinks for GCC target lib/include directories, and runs a compile smoke test.
#
# Environment:
#   TARGET_ARCH   amd64, arm64, or riscv64
#   GCC_VERSION   e.g. 16.1.0
#   BUILD_MODE    cross or native

_swap_gcc_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${_swap_gcc_script_dir}/../01-core/modules.sh"
source_module platform.sh

main() {
  : "${TARGET_ARCH:?TARGET_ARCH is required}"
  : "${GCC_VERSION:?GCC_VERSION is required}"

  if [ "${TARGET_ARCH}" != "amd64" ] && [ "${BUILD_MODE:-}" = "cross" ]; then
    local native_gcc="/opt/gcc-${GCC_VERSION}-native-${TARGET_ARCH}"
    if [ ! -d "${native_gcc}" ]; then
      echo "ERROR: expected target-native GCC at ${native_gcc} but not found" >&2
      echo "ERROR: Rebuild the toolchain image (build-cross-compiler.sh) to produce" >&2
      echo "ERROR: the Canadian cross GCC, then rebuild this android image." >&2
      exit 1
    fi

    assert_elf_arch "${native_gcc}/bin/gcc" "${TARGET_ARCH}"
    assert_elf_arch "${native_gcc}/bin/g++" "${TARGET_ARCH}"

    rm -rf "/opt/gcc-${GCC_VERSION}"
    cp -a "${native_gcc}" "/opt/gcc-${GCC_VERSION}"

    assert_elf_arch "/opt/gcc-${GCC_VERSION}/bin/gcc" "${TARGET_ARCH}"
    echo "Replaced host GCC with target-native ${TARGET_ARCH} GCC at /opt/gcc-${GCC_VERSION}"

    local triplet
    triplet="$(arch_deb_multiarch_triplet_for "${TARGET_ARCH}")"
    if [ -n "${triplet}" ]; then
      local gcc_target_lib="/opt/gcc-${GCC_VERSION}/${triplet}/lib"
      local sys_multiarch_lib="/usr/lib/${triplet}"
      if [ ! -d "${gcc_target_lib}" ] || [ -z "$(ls -A "${gcc_target_lib}" 2>/dev/null)" ]; then
        rm -rf "${gcc_target_lib}"
        mkdir -p "$(dirname "${gcc_target_lib}")"
        ln -sf "${sys_multiarch_lib}" "${gcc_target_lib}"
        echo "Linked GCC target lib ${gcc_target_lib} -> ${sys_multiarch_lib}"
      fi

      local gcc_target_include="/opt/gcc-${GCC_VERSION}/${triplet}/include"
      local sys_multiarch_include="/usr/include/${triplet}"
      if [ ! -e "${gcc_target_include}" ]; then
        mkdir -p "$(dirname "${gcc_target_include}")"
        ln -sf "${sys_multiarch_include}" "${gcc_target_include}"
        echo "Linked GCC target include ${gcc_target_include} -> ${sys_multiarch_include}"
      fi
    fi

    echo "int main(){}" > /tmp/gcc_smoke.c
    if /opt/gcc-${GCC_VERSION}/bin/gcc /tmp/gcc_smoke.c -o /tmp/gcc_smoke 2>/tmp/gcc_smoke.err; then
      file /tmp/gcc_smoke
      echo "GCC compile smoke test PASSED"
    else
      echo "WARNING: native GCC cannot compile trivial program (cross-build host limitation)"
      cat /tmp/gcc_smoke.err 2>/dev/null || true
    fi
    rm -f /tmp/gcc_smoke.c /tmp/gcc_smoke /tmp/gcc_smoke.err
  elif [ "${TARGET_ARCH}" = "amd64" ]; then
    assert_elf_arch "/opt/gcc-${GCC_VERSION}/bin/gcc" "amd64"
    echo "Using host-native amd64 GCC at /opt/gcc-${GCC_VERSION}"
  fi
}

main "$@"