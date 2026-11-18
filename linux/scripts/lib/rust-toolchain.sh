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

# wasm_bindgen_lock_version <Cargo.lock>: the locked wasm-bindgen crate's version, empty when there is none.
wasm_bindgen_lock_version() {
  # tr: a CRLF checkout's lines end in \r, which the exact name match would never see.
  tr -d '\r' <"$1" | awk '$0 == "name = \"wasm-bindgen\"" { getline; if (sub(/^version = "/, "") && sub(/"$/, "")) print; exit }'
}

# ensure_wasm_bindgen <Cargo.lock>: wasm-bindgen-cli refuses a module from any other wasm-bindgen, so PATH's must be the lock's.
ensure_wasm_bindgen() {
  local lock="${1:-}" want have
  if [ ! -f "${lock}" ]; then
    warn "ensure_wasm_bindgen: no Cargo.lock at '${lock}'"
    return 1
  fi
  want="$(wasm_bindgen_lock_version "${lock}")"
  if [ -z "${want}" ]; then
    warn "no wasm-bindgen in ${lock}: wasm-bindgen-cli cannot be pinned"
    return 1
  fi
  have="$(wasm-bindgen --version 2>/dev/null | awk '{print $2}')"
  if [ "${have}" = "${want}" ]; then
    info "wasm-bindgen ${want} already on PATH, as ${lock} pins it"
    return 0
  fi
  info "installing wasm-bindgen-cli ${want} for ${lock} (PATH has: ${have:-none})"
  cargo install --locked wasm-bindgen-cli --version "${want}" || return $?
  # cargo installs into CARGO_HOME/bin; a PATH that misses it, or puts another first, still runs the wrong one.
  have="$(wasm-bindgen --version 2>/dev/null | awk '{print $2}')"
  if [ "${have}" != "${want}" ]; then
    warn "cargo installed wasm-bindgen ${want} into ${CARGO_HOME:-${HOME}/.cargo}/bin, but PATH runs ${have:-none}"
    return 1
  fi
}
