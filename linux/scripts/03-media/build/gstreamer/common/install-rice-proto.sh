#!/usr/bin/env bash
set -euo pipefail

# Build and install the rice-proto C library (librice's sans-IO ICE crate) so
# that the gst-plugins-rs webrtcbin2 plugin can be built.
#
# webrtcbin2 -> librice (non-optional rice-c dep) -> rice-c's build.rs needs the
# *system* `rice-proto` pkg-config library (it only builds an internal copy when
# building from the librice workspace, which is not the case from crates.io).
# Installing rice-proto's C API via cargo-c provides `rice-proto.pc`, which
# satisfies both rice-c's system-deps lookup AND meson's dependency('rice-proto')
# check (so webrtcbin2 is enabled in the monorepo meson build too).
#
# This is best-effort: webrtcbin2 is optional, so any failure here only means the
# plugin is skipped — it never fails the whole GStreamer stage.

_RICE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${_RICE_DIR}/../../../core/common.sh"
media_common_init "${_RICE_DIR}"

# Only relevant when we are attempting every gst-plugins-rs crate; webrtcbin2 is
# the sole consumer of rice-proto.
if [ "${GST_RS_BUILD_ALL:-true}" != "true" ]; then
  echo "GST_RS_BUILD_ALL is off; skipping rice-proto (webrtcbin2 not built)"
  exit 0
fi

# Keep in sync with the librice version pinned by gst-plugins-rs webrtcbin2's
# Cargo.toml (meson also requires rice-proto >= 0.4.2).
RICE_VERSION="${RICE_VERSION:-v0.4.3}"
PREFIX="/usr/local"
LIBDIR="${PREFIX}/lib"
TMPDIR="/tmp/librice-$$"

if ! command -v cargo-cinstall >/dev/null 2>&1 && ! cargo cinstall --help >/dev/null 2>&1; then
  echo "WARN: cargo-c (cargo cinstall) not available; cannot build rice-proto — webrtcbin2 will be skipped" >&2
  exit 0
fi

echo "Building rice-proto ${RICE_VERSION} C library (for webrtcbin2)..."
rm -rf "${TMPDIR}"
if ! git clone --depth 1 --branch "${RICE_VERSION}" https://github.com/ystreet/librice.git "${TMPDIR}"; then
  echo "WARN: failed to clone librice ${RICE_VERSION}; webrtcbin2 will be skipped" >&2
  exit 0
fi
cd "${TMPDIR}"

# cargo-c auto-enables the crate's `capi` feature and reads [package.metadata.capi].
cinstall_args=(-p rice-proto --release --prefix="${PREFIX}" --libdir="${LIBDIR}")

# Cross builds: emit the target-arch library. rice-proto is pure Rust + a C API,
# so it cross-compiles cleanly given the installed rust target.
if [ "${BUILD_MODE:-native}" = "cross" ]; then
  rust_target=""
  if command -v cross_target_rust_triple >/dev/null 2>&1; then
    rust_target="$(cross_target_rust_triple 2>/dev/null || true)"
  fi
  if [ -z "${rust_target}" ]; then
    case "${TARGET_ARCH:-${TARGETARCH:-amd64}}" in
      arm64)   rust_target="aarch64-unknown-linux-gnu" ;;
      riscv64) rust_target="riscv64gc-unknown-linux-gnu" ;;
      amd64)   rust_target="x86_64-unknown-linux-gnu" ;;
    esac
  fi
  [ -n "${rust_target}" ] && cinstall_args+=(--target "${rust_target}")
  echo "Cross build: cinstalling rice-proto for target '${rust_target:-<default>}'"
fi

if ! cargo cinstall "${cinstall_args[@]}"; then
  echo "WARN: cargo cinstall rice-proto failed; webrtcbin2 will be skipped" >&2
  cd /
  rm -rf "${TMPDIR}"
  exit 0
fi

# Refresh the linker cache and verify pkg-config can resolve it. /usr/local/lib
# and its pkgconfig dir are already on the gstreamer stage's PKG_CONFIG paths.
ldconfig 2>/dev/null || true
if PKG_CONFIG_PATH="${LIBDIR}/pkgconfig${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}" pkg-config --exists rice-proto 2>/dev/null; then
  echo "rice-proto $(PKG_CONFIG_PATH="${LIBDIR}/pkgconfig" pkg-config --modversion rice-proto 2>/dev/null) installed to ${PREFIX} (webrtcbin2 enabled)"
else
  echo "WARN: rice-proto.pc not found after install; webrtcbin2 may be skipped" >&2
fi

cd /
rm -rf "${TMPDIR}"
