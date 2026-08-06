#!/usr/bin/env bash
# rust-toolchain.sh - Rust toolchain prerequisites that must not assume rustup.
#
# Source it, then call the functions. Self-sufficient: it defines info/warn
# fallbacks the same way the other libs here do, so it works whether or not the
# caller has its own logging helpers.
#
#   source "<containerhub>/linux/scripts/lib/rust-toolchain.sh"
#   ensure_wasm32_target || echo "cannot build wasm here"

if ! declare -F info >/dev/null 2>&1; then
  info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
fi
if ! declare -F warn >/dev/null 2>&1; then
  warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
fi

# Make the wasm32-unknown-unknown target usable WITHOUT assuming rustup exists.
#
# The cross images install Rust from the distribution, not via rustup: cargo
# and rustc are /bin/cargo and /bin/rustc with a sysroot like /usr/lib/rust-1.x,
# and /usr/local/cargo/bin only symlinks them. `rustup target add` therefore
# exits 127 - "command not found" - and under `set -e` that kills the calling
# step before it does any work. A consumer's wasm size-budget gate died exactly
# that way on 2026-08-06, and the same line silently short-circuited a docs
# demo rebuild's `&&` chain, so the docs step passed while the budget step
# failed on the identical command.
#
# Returns 0 when a wasm32 build can proceed, 1 when the toolchain simply cannot
# target wasm. Callers decide what that means for them - a size gate that
# cannot weigh anything should SKIP loudly rather than report a regression it
# did not measure.
ensure_wasm32_target() {
  if command -v rustup >/dev/null 2>&1; then
    rustup target add wasm32-unknown-unknown
    return $?
  fi

  # No rustup: ask rustc directly whether std for the target is installed.
  # --print target-libdir names the directory even when it does not exist, so
  # the existence check is the actual probe.
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
