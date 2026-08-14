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
: "${RUST_VERSION:=1.97.1}"
: "${CARGO_C_VERSION:=0.10.24}"

# Download rustup-init to a file (never pipe curl into sh: a truncated stream
# would execute a partial script), then optionally pin it: RUSTUP_INIT_SHA256
# comes from the environment, falling back to the versions.env key when the
# core mount is present. Empty = skip (upstream rotates the script; see the
# key's comment in versions.env).
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

cargo install --locked --version "${CARGO_C_VERSION}" cargo-c

try_rustup() {
  "$@" && return 0
  printf 'WARNING: optional rustup command failed: %s\n' "$*" >&2
}

# clippy and rustfmt are NOT optional (no try_rustup), for the same reason the
# wasm target below is not. `--profile minimal` ships neither. The runtime stage
# has no rustup, so a consumer cannot add a missing component itself — and it
# does not even get a clean error: the images also carry Ubuntu's cargo/clippy
# debs at /bin, so `cargo clippy` silently falls through to THAT one and builds
# the project with rustc 1.93.1 instead of the pinned toolchain. The symptom is
# unrelated-looking, e.g.
#   error[E0658]: use of unstable library feature `array_windows`
#     --> .../epaint-0.36.1/src/shapes/shape.rs
# for code that compiles fine on the pinned rustc. A silently-degraded
# toolchain is worse than a failed image build.
rustup component add clippy

# rustfmt, on the DEFAULT toolchain. NOT optional, for the same reason as the
# wasm target below: `--profile minimal` ships neither, the runtime stage has no
# rustup for a consumer to add one itself, and a consumer lane that calls
# `cargo fmt` therefore cannot run its format gate at all - it dies with
#   error: 'cargo-fmt' is not installed for the toolchain '<ver>-<host>'
# RustProjectTemplate's workflow had been asserting in a comment that "rustfmt
# and clippy are baked in at image-build time" while only clippy actually was;
# the format gate was dead from the moment it stopped being
# continue-on-error. Failing the image build is the correct response to a
# missing lint component - a gate that cannot run is the failure mode this
# repo keeps paying for.
rustup component add rustfmt

# The browser build target, on the DEFAULT (stable) toolchain: consumer CI
# lanes run `cargo check --target wasm32-unknown-unknown` on stable, and the
# runtime containers have no rustup on PATH to add it themselves - without
# this the RustProjectTemplate wasm gate can only skip (found 2026-07-22).
# Not optional (no try_): if the wasm target is missing the gate is dead.
rustup target add wasm32-unknown-unknown

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
