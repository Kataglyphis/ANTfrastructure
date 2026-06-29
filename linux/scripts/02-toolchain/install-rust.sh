#!/usr/bin/env bash
set -euo pipefail

# install-rust.sh
# Installs rustup, cargo-c, nightly toolchain, and cross-compilation targets
# for the host and all target architectures. Called from Dockerfile.toolchain.

if [ -f /opt/scripts/core/platform.sh ]; then
  # shellcheck disable=SC1091
  source /opt/scripts/core/platform.sh
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

curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
rustc --version
cargo --version

cargo install --locked cargo-c

try_rustup() {
  "$@" && return 0
  printf 'WARNING: optional rustup command failed: %s\n' "$*" >&2
}

try_rustup rustup component add clippy

nightly_toolchain="nightly-${host_rust_target}"
try_rustup rustup toolchain install "${nightly_toolchain}"
try_rustup rustup component add rust-src --toolchain "${nightly_toolchain}"
try_rustup rustup target add wasm32-unknown-unknown --toolchain "${nightly_toolchain}"

for target in ${rust_targets//,/ }; do
  rust_target="$(rust_target_triple_for_arch "${target}")" || {
    echo "Unsupported Rust target: ${target}" >&2
    exit 1
  }
  rustup target add "${rust_target}"
  try_rustup rustup target add --toolchain "${nightly_toolchain}" "${rust_target}"
done
