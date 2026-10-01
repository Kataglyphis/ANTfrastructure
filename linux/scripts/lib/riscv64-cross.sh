#!/usr/bin/env bash
# Sourced (no shell options): riscv64 cross builds + QEMU test runs inside the amd64 image. docs/riscv64-cross-test-lanes.md#the-pieces
[ -n "${_RISCV64_CROSS_SH_LOADED:-}" ] && return 0
_RISCV64_CROSS_SH_LOADED=1

# shellcheck source=./log-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/log-bootstrap.sh"

_RISCV64_CROSS_HUB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

# The image's own riscv64 GCC default. See docs/riscv64-rva23-baseline.md#where-it-is-set
RISCV64_CROSS_MARCH="rv64gcv_zicsr_zifencei_zba_zbb_zbs_zicond"
# The image's riscv64 glibc needs RVV 1.0, which QEMU's rv64 and rva22u64 models lack (SIGILL).
RISCV64_CROSS_QEMU_CPU="rva23u64"

# riscv64_cross_llvm_dir [root]: the newest LLVM under root/llvm-* that has a riscv64 backend.
riscv64_cross_llvm_dir() {
  local root="${1:-/usr/lib}" d
  while IFS= read -r d; do
    [ -n "${d}" ] || continue
    if "${d}/bin/llc" --version 2>/dev/null | grep -q -e ' riscv64 '; then
      printf '%s' "${d}"
      return 0
    fi
  done < <(find "${root}" -maxdepth 1 -name 'llvm-*' 2>/dev/null | sort -V -r)
  return 1
}

# riscv64_cross_write_wrappers <bin-dir> <llvm-dir> <sysroot>: triple-named clang drivers with the cross contract baked in.
riscv64_cross_write_wrappers() {
  local bin="$1" llvm="$2" sysroot="$3" flags tool
  case "${bin}${llvm}${sysroot}" in
    *[[:space:]]*) warn "riscv64-cross: paths with whitespace are not supported"; return 1 ;;
  esac
  # The riscv64 GCC keeps libstdc++ in lib/, where clang does not look for a cross GCC.
  flags="--target=riscv64-linux-gnu --sysroot=${sysroot} --gcc-toolchain=${sysroot}/opt/gcc-16.2.0"
  flags+=" -march=${RISCV64_CROSS_MARCH} -mabi=lp64d"
  flags+=" --start-no-unused-arguments -fuse-ld=lld -L${sysroot}/opt/gcc-16.2.0/lib --end-no-unused-arguments"
  mkdir -p "${bin}" || return 1
  for tool in clang clang++; do
    printf '#!/bin/sh\nexec "%s/bin/%s" %s "$@"\n' "${llvm}" "${tool}" "${flags}" > "${bin}/riscv64-linux-gnu-${tool}" || return 1
    chmod +x "${bin}/riscv64-linux-gnu-${tool}" || return 1
  done
}

# riscv64_cross_pkg_config_libdir <sysroot>: the riscv64 .pc directories, in the image's PKG_CONFIG_PATH order.
riscv64_cross_pkg_config_libdir() {
  local s="$1"
  printf '%s' "${s}/usr/local/lib/pkgconfig:${s}/opt/gstreamer/lib/pkgconfig:${s}/opt/opencv5/lib/pkgconfig"
  printf '%s' ":${s}/opt/libcamera/lib/pkgconfig:${s}/opt/libcamera/lib64/pkgconfig:${s}/opt/ffmpeg/lib/pkgconfig"
  printf '%s' ":${s}/usr/lib/riscv64-linux-gnu/pkgconfig:${s}/usr/share/pkgconfig"
}

# riscv64_cross_env [bin-dir]: exports the compilers, Cargo, pkg-config, CMake and QEMU settings; fails when riscv64 ELF cannot run.
riscv64_cross_env() {
  local sysroot="${RISCV64_SYSROOT:-/opt/riscv64-sysroot}" bin="${1:-${TMPDIR:-/tmp}/riscv64-cross-bin}" llvm
  if [ ! -e "${sysroot}/lib/ld-linux-riscv64-lp64d.so.1" ]; then
    warn "riscv64-cross: no riscv64 sysroot at ${sysroot}; build one with linux/scripts/02-toolchain/riscv64-sysroot.sh"
    return 1
  fi
  llvm="$(riscv64_cross_llvm_dir)" || { warn "riscv64-cross: no LLVM with a riscv64 backend under /usr/lib/llvm-*"; return 1; }
  riscv64_cross_write_wrappers "${bin}" "${llvm}" "${sysroot}" || return 1

  export RISCV64_SYSROOT="${sysroot}" RISCV64_CROSS_BIN="${bin}" RISCV64_CROSS_LLVM="${llvm}"
  export RISCV64_CMAKE_TOOLCHAIN_FILE="${_RISCV64_CROSS_HUB_ROOT}/cmake/toolchains/riscv64-linux-gnu.cmake"
  RISCV64_PKG_CONFIG_LIBDIR="$(riscv64_cross_pkg_config_libdir "${sysroot}")"
  export RISCV64_PKG_CONFIG_LIBDIR

  export CC_riscv64gc_unknown_linux_gnu="${bin}/riscv64-linux-gnu-clang"
  export CXX_riscv64gc_unknown_linux_gnu="${bin}/riscv64-linux-gnu-clang++"
  export AR_riscv64gc_unknown_linux_gnu="${llvm}/bin/llvm-ar"
  export CARGO_TARGET_RISCV64GC_UNKNOWN_LINUX_GNU_LINKER="${bin}/riscv64-linux-gnu-clang"
  # Rust has no gcv triple; the image's Rust objects carry the same features. See docs/riscv64-rva23-baseline.md
  export CARGO_TARGET_RISCV64GC_UNKNOWN_LINUX_GNU_RUSTFLAGS="-C target-feature=+v,+zvl128b"
  export PKG_CONFIG_ALLOW_CROSS=1
  export PKG_CONFIG_SYSROOT_DIR_riscv64gc_unknown_linux_gnu="${sysroot}"
  export PKG_CONFIG_LIBDIR_riscv64gc_unknown_linux_gnu="${RISCV64_PKG_CONFIG_LIBDIR}"

  # QEMU remaps absolute opens into the sysroot, so the image's arch-neutral paths reach riscv64 files.
  export QEMU_LD_PREFIX="${sysroot}"
  export QEMU_CPU="${QEMU_CPU:-${RISCV64_CROSS_QEMU_CPU}}"
  # Images before CON48 leave the entrypoint's x86_64 SDK dir here; the link re-roots to riscv64 in CMake and under QEMU.
  export VULKAN_SDK=/opt/vulkan/active
  export VK_ADD_LAYER_PATH=/opt/vulkan/active/share/vulkan/explicit_layer.d
  # execve is not remapped, so a forked scanner would be the amd64 one.
  export GST_REGISTRY_FORK=no

  if ! "${sysroot}/lib/ld-linux-riscv64-lp64d.so.1" --version >/dev/null 2>&1; then
    warn "riscv64-cross: riscv64 ELF does not execute: register QEMU binfmt with the F flag first (setup-riscv64-cross action)"
    return 1
  fi
  info "riscv64-cross: $("${llvm}/bin/clang" --version | head -n 1), sysroot ${sysroot}, QEMU_CPU=${QEMU_CPU}"
}
