#!/usr/bin/env bash
set -euo pipefail

# install-rust.sh
# Installs rustup, cargo-c, nightly toolchain, and cross-compilation targets
# for the host and all target architectures. Called from Dockerfile.toolchain.

if [ -f /opt/scripts/core/platform.sh ]; then
  # shellcheck disable=SC1091
  source /opt/scripts/core/platform.sh
fi

# cross-env.sh provides for_each_cross_target (the shared cross-target loop).
if [ -f /opt/scripts/core/cross-env.sh ]; then
  # shellcheck disable=SC1091
  source /opt/scripts/core/cross-env.sh
fi

host_arch="${TARGETARCH:-$(dpkg --print-architecture)}"
host_rust_target="$(rust_target_triple_for_arch "${host_arch}")" || {
  echo "Unsupported Rust host architecture: ${host_arch}" >&2
  exit 1
}

if [ "${BUILD_MODE:-native}" = "cross" ]; then
  rust_targets="$(arch_list_csv_normalize "${CROSS_TARGETS}" 2>/dev/null || printf '%s' "${CROSS_TARGETS}")"
else
  rust_targets="${host_arch}"
fi

# Pin the toolchain: an unpinned `rustup | sh` installs TODAY's stable, so a
# rebuild produced a different rustc/cargo than the shipped images (found in
# the 2026-07 chain review). Pins live in versions.env; env wins if set.
: "${RUST_VERSION:=1.96.0}"
: "${CARGO_C_VERSION:=0.10.23}"
curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain "${RUST_VERSION}"
rustc --version
cargo --version

cargo install --locked --version "${CARGO_C_VERSION}" cargo-c

try_rustup() {
  "$@" && return 0
  printf 'WARNING: optional rustup command failed: %s\n' "$*" >&2
}

try_rustup rustup component add clippy

# Pinned nightly (a bare "nightly" floats to today's build).
: "${RUST_NIGHTLY_TOOLCHAIN:=nightly-2026-06-28}"
nightly_toolchain="${RUST_NIGHTLY_TOOLCHAIN}-${host_rust_target}"
try_rustup rustup toolchain install "${nightly_toolchain}"
try_rustup rustup component add rust-src --toolchain "${nightly_toolchain}"
try_rustup rustup target add wasm32-unknown-unknown --toolchain "${nightly_toolchain}"

# Per-target callback: add the stable + pinned-nightly rust target.
add_rust_target() {
  local target="$1" rust_target
  rust_target="$(rust_target_triple_for_arch "${target}")" || {
    echo "Unsupported Rust target: ${target}" >&2
    exit 1
  }
  rustup target add "${rust_target}"
  try_rustup rustup target add --toolchain "${nightly_toolchain}" "${rust_target}"
}

# amd64 is included: the host/target arch itself must get its rust target added.
for_each_cross_target add_rust_target --include-amd64 "${rust_targets}"
