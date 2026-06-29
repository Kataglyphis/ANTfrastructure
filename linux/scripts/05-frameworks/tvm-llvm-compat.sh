#!/usr/bin/env bash
set -euo pipefail

# tvm-llvm-compat.sh
# Compiler wrapper generator for TVM's LLVM integration.
# Extracted from tvm.sh to reduce the size of the main build script.
#
# Problem:
# TVM's LLVM integration adds `-isystem /usr/lib/llvm-XX/include` to the compile command.
# On Ubuntu, that directory may contain a top-level `cxxabi.h` that conflicts with
# GCC's libstdc++ headers (see __cxa_init_primary_exception conflict).
#
# Approach:
# Create a tiny shim include dir that provides `cxxabi.h` forwarding to GCC's header,
# then wrap the compiler to inject `-I<shim>` as the first argument so it wins over
# `-isystem /usr/lib/llvm-XX/include`.
#
# Prints: "<wrapped_cc> <wrapped_cxx>" (or original compilers if no action needed)

maybe_wrap_compiler_to_prefer_gcc_cxxabi_header() {
  local llvm_config_path="$1"
  local build_dir="$2"
  local real_cc="$3"
  local real_cxx="$4"

  local out_cc="$real_cc"
  local out_cxx="$real_cxx"

  if [ -z "$llvm_config_path" ] || ! command -v "$llvm_config_path" >/dev/null 2>&1; then
    echo "$out_cc $out_cxx"
    return 0
  fi

  local llvm_includedir
  llvm_includedir="$($llvm_config_path --includedir 2>/dev/null || true)"
  if [ -z "$llvm_includedir" ] || [ ! -f "$llvm_includedir/cxxabi.h" ]; then
    echo "$out_cc $out_cxx"
    return 0
  fi

  local gcc_major=""
  local gcc_full=""
  if command -v "$real_cxx" >/dev/null 2>&1; then
    gcc_full="$($real_cxx -dumpfullversion -dumpversion 2>/dev/null || true)"
    [ -n "$gcc_full" ] || gcc_full="$($real_cxx -dumpversion 2>/dev/null || true)"
    gcc_major="${gcc_full%%.*}"
  fi
  # Fallback to the canonical GCC version from versions.env if present
  # (avoids the stale hardcoded `14` that predates the source-built GCC 16.x
  # toolchain). GCC_VERSION is exported by artifact-common.sh / common.sh.
  if [ -z "$gcc_major" ] && [ -n "${GCC_VERSION:-}" ]; then
    gcc_major="${GCC_VERSION%%.*}"
  fi
  # Last-resort safety net (matches versions.env GCC_VERSION=16.1.0).
  [ -n "$gcc_major" ] || gcc_major="16"

  local real_cxx_path="${real_cxx}"
  if [ -x "$real_cxx" ]; then
    real_cxx_path="$real_cxx"
  elif command -v "$real_cxx" >/dev/null 2>&1; then
    real_cxx_path="$(command -v "$real_cxx")"
  fi
  if command -v readlink >/dev/null 2>&1; then
    real_cxx_path="$(readlink -f "$real_cxx_path" 2>/dev/null || echo "$real_cxx_path")"
  fi

  local gcc_prefix=""
  case "$real_cxx_path" in
    */bin/*) gcc_prefix="${real_cxx_path%/bin/*}" ;;
  esac

  local gcc_cxxabi_header=""
  local -a cxxabi_candidates=(
    "/usr/include/c++/${gcc_full}/cxxabi.h"
    "/usr/include/c++/${gcc_major}/cxxabi.h"
  )
  if [ -n "$gcc_prefix" ]; then
    cxxabi_candidates+=(
      "${gcc_prefix}/include/c++/${gcc_full}/cxxabi.h"
      "${gcc_prefix}/include/c++/${gcc_major}/cxxabi.h"
    )
  fi

  local c
  for c in "${cxxabi_candidates[@]}"; do
    if [ -n "$c" ] && [ -r "$c" ]; then
      gcc_cxxabi_header="$c"
      break
    fi
  done

  if [ -z "$gcc_cxxabi_header" ]; then
    log "Workaround skipped: could not locate GCC libstdc++ cxxabi.h (needed to override $llvm_includedir/cxxabi.h)" >&2
    echo "$out_cc $out_cxx"
    return 0
  fi

  local shim_root="$build_dir/.kataglyphis-include-shim"
  local shim_include="$shim_root/include"
  mkdir -p "$shim_include"

  cat >"$shim_include/cxxabi.h" <<EOF
#pragma once
#include <${gcc_cxxabi_header}>
EOF

  local wrapper_dir="$shim_root/wrappers"
  mkdir -p "$wrapper_dir"

  local wrapper_cc="$wrapper_dir/cc"
  local wrapper_cxx="$wrapper_dir/cxx"

  cat >"$wrapper_cc" <<EOF
#!/usr/bin/env bash
set -euo pipefail
exec "$real_cc" -I"$shim_include" "\$@"
EOF

  cat >"$wrapper_cxx" <<EOF
#!/usr/bin/env bash
set -euo pipefail
exec "$real_cxx" -I"$shim_include" "\$@"
EOF

  chmod +x "$wrapper_cc" "$wrapper_cxx"

  log "Workaround: preferring GCC cxxabi.h over LLVM's ($llvm_includedir/cxxabi.h) via compiler wrapper" >&2
  out_cc="$wrapper_cc"
  out_cxx="$wrapper_cxx"

  echo "$out_cc $out_cxx"
}
