#!/usr/bin/env bash
# Publish a source LLVM loader path; writing the cache does not prove library ABI or inference.
publish_llvm_target_ld_path() {
  local prefix="${1:-/usr/local/llvm-target}" config="${2:-/etc/ld.so.conf.d/000-llvm-target.conf}"
  printf '%s\n' "${prefix}/lib" > "${config}" || return $?
  ldconfig
}
