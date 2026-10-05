#!/usr/bin/env bash
set -euo pipefail

# Also rerun on foreign-arch runtime images. docs/failure-modes.md#the-copied-rust-toolchain-is-the-builders-arch

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

# Pinned: an unpinned rustup installs today's stable, not what the shipped images carry.
: "${RUST_VERSION:=1.97.1}"
: "${CARGO_C_VERSION:=0.10.24}"

# Download to a file, never curl | sh (a truncated stream runs half a script); RUSTUP_INIT_SHA256 pins it.
if [ -z "${RUSTUP_INIT_SHA256:-}" ] && [ -f /opt/scripts/core/versions.env ]; then
  RUSTUP_INIT_SHA256="$(sed -n 's/^RUSTUP_INIT_SHA256=//p' /opt/scripts/core/versions.env)"
fi
rustup_init="$(mktemp "${TMPDIR:-/tmp}/rustup-init-XXXXXX.sh")"
curl --proto '=https' --tlsv1.2 -fsSL --retry 3 -o "${rustup_init}" https://sh.rustup.rs
if [ -n "${RUSTUP_INIT_SHA256:-}" ]; then
  printf '%s  %s\n' "${RUSTUP_INIT_SHA256}" "${rustup_init}" | sha256sum -c - || {
    echo "ERROR: rustup-init script does not match pinned RUSTUP_INIT_SHA256 (upstream rotated it, or tampering)" >&2
    rm -f "${rustup_init}"
    exit 1
  }
fi
sh "${rustup_init}" -y --profile minimal --default-toolchain "${RUST_VERSION}"
rm -f "${rustup_init}"
rustc --version
cargo --version

if [ "${RUST_INSTALL_CARGO_C:-1}" = "1" ]; then
  cargo install --locked --version "${CARGO_C_VERSION}" cargo-c
fi

try_rustup() {
  "$@" && return 0
  printf 'WARNING: optional rustup command failed: %s\n' "$*" >&2
}

# Required: the runtime has no rustup, and cargo clippy would silently fall back to Ubuntu's older /bin toolchain.
rustup component add clippy

# Required: without rustfmt a consumer's cargo fmt gate cannot run at all.
rustup component add rustfmt

# Required: consumer lanes check wasm32 on stable, and the runtime has no rustup to add it.
rustup target add wasm32-unknown-unknown

# Required: Cargokit builds an Android app's Rust for it, and adding it per build needs the network.
rustup target add aarch64-linux-android

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
