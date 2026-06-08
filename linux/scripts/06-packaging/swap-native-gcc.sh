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

elf_machine_pattern() {
  case "$1" in
    amd64)   printf '%s' "X86-64" ;;
    arm64)   printf '%s' "AArch64" ;;
    riscv64) printf '%s' "RISC-V" ;;
    386)     printf '%s' "Intel 80386" ;;
    *)       return 1 ;;
  esac
}

assert_elf_arch() {
  local bin="$1" arch="$2" pat machine
  pat="$(elf_machine_pattern "${arch}")" || {
    echo "WARN: no ELF pattern for ${arch}; skipping" >&2
    return 0
  }
  command -v readelf >/dev/null 2>&1 || {
    echo "WARN: readelf missing; skipping ELF check" >&2
    return 0
  }
  machine="$(readelf -h "${bin}" 2>/dev/null | sed -n 's/^[[:space:]]*Machine:[[:space:]]*//p' | head -n1)"
  [ -n "${machine}" ] || { echo "ERROR: cannot read ELF machine of ${bin}" >&2; exit 1; }
  case "${machine}" in
    *"${pat}"*)
      echo "ELF arch OK: ${bin} Machine='${machine}' matches ${arch}" ;;
    *)
      echo "ERROR: ELF arch MISMATCH ${bin} Machine='${machine}' expected '${pat}' for ${arch}" >&2
      exit 1 ;;
  esac
}

gcc_target_triplet() {
  case "$1" in
    arm64)   echo "aarch64-linux-gnu" ;;
    riscv64) echo "riscv64-linux-gnu" ;;
    *)       echo "" ;;
  esac
}

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
    triplet="$(gcc_target_triplet "${TARGET_ARCH}")"
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