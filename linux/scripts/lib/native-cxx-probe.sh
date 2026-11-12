#!/usr/bin/env bash
# Native probes share compiler selection while preserving explicit caller output bindings and raw failures.
source "$(dirname "${BASH_SOURCE[0]}")/cli-value-options.sh"

native_cxx_probe_setup() {
  local cache_launcher
  local -n probe_gcc_root="$3" probe_toolchain="$4"
  source "$1/compiler-cache-utils.sh" || return
  declare -F compiler_cache_guarded_launcher >/dev/null || { printf 'Missing guarded compiler-cache API\n' >&2; return 1; }
  source "$1/cross-gcc.sh" || return
  declare -F gcc_toolchain_resolve_prefix >/dev/null || { printf 'Missing GCC toolchain resolver\n' >&2; return 1; }
  cache_launcher="$(compiler_cache_guarded_launcher "$1")" || return
  printf -v "$2" '%s' "${cache_launcher}"
  probe_gcc_root="$(gcc_toolchain_resolve_prefix)" || return
  probe_toolchain=()
  probe_toolchain+=("--gcc-toolchain=${probe_gcc_root}")
}

# Compiler identity and GCC selection travel together in every native probe receipt.
native_cxx_probe_record() {
  clang++ --version > "$1/compiler.txt" || return
  printf '%s\n' "$2" > "$1/gcc-toolchain.txt"
}
