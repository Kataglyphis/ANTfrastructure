#!/usr/bin/env bash
# Rust toolchain prerequisites that must not assume rustup; log-bootstrap.sh makes it self-sufficient.

[ -n "${_RUST_TOOLCHAIN_LIB_LOADED:-}" ] && return 0
_RUST_TOOLCHAIN_LIB_LOADED=1
# shellcheck source=./log-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/log-bootstrap.sh"

# Cross images ship distro Rust, where rustup exits 127; returns 1 when wasm is impossible, for the caller to decide.
ensure_wasm32_target() {
  if command -v rustup >/dev/null 2>&1; then
    rustup target add wasm32-unknown-unknown
    return $?
  fi

  # --print target-libdir names the dir even when absent, so its existence is the probe.
  local libdir
  if libdir="$(rustc --print target-libdir --target wasm32-unknown-unknown 2>/dev/null)" \
     && [ -d "${libdir}" ]; then
    info "rustup not present; wasm32-unknown-unknown std already installed (${libdir})"
    return 0
  fi

  warn "rustup is not installed AND this toolchain has no wasm32-unknown-unknown std"
  warn "(rustc sysroot: $(rustc --print sysroot 2>/dev/null || echo unknown)) - cannot build wasm here"
  return 1
}
