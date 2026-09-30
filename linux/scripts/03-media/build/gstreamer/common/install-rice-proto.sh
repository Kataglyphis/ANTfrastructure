#!/usr/bin/env bash
set -euo pipefail

# webrtcbin2's rice-c from crates.io needs a system rice-proto.pc; best-effort, as a failure only skips that plugin.

_RICE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${_RICE_DIR}/../../../core/common.sh"
media_common_init "${_RICE_DIR}"

# webrtcbin2 is the only rice-proto consumer.
if [ "${GST_RS_BUILD_ALL:-true}" != "true" ]; then
  echo "GST_RS_BUILD_ALL is off; skipping rice-proto (webrtcbin2 not built)"
  exit 0
fi

# Keep in sync with webrtcbin2's librice pin in gst-plugins-rs (meson requires rice-proto >= 0.4.2).
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

# rice-proto is pure Rust plus a C API, so it cross-compiles given the installed rust target.
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

  # Without a target linker cargo links the cdylib with the host cc; target-only vars keep host build scripts native.
  if [ -n "${rust_target}" ] && command -v resolve_cross_cc_cxx_for_arch >/dev/null 2>&1; then
    rice_cross_cc="$( resolve_cross_cc_cxx_for_arch "${TARGET_ARCH:-${TARGETARCH:-}}" >/dev/null 2>&1 && printf '%s' "${CC:-}" )"
    rice_rust_env="$(printf '%s' "${rust_target}" | tr 'a-z-' 'A-Z_')"
    rice_rust_lower="$(printf '%s' "${rust_target}" | tr '-' '_')"
    if export_cargo_target_linker "${rice_rust_env}" "${rice_rust_lower}" "${rice_cross_cc}"; then
      echo "Cross build: rice-proto target linker = ${rice_cross_cc} (CARGO_TARGET_${rice_rust_env}_LINKER)"
    else
      echo "WARN: could not resolve cross gcc for '${TARGET_ARCH:-?}'; rice-proto may fail to link (webrtcbin2 skipped)" >&2
    fi
  fi

  # openssl-sys's probe: the cross gcc skips /usr/include/<triplet> (opensslconf.h), and openssl.pc has empty Cflags.
  target_triplet=""
  if command -v cross_target_triplet >/dev/null 2>&1; then
    target_triplet="$(cross_target_triplet 2>/dev/null || true)"
  fi
  if [ -n "${rust_target}" ] && [ -n "${target_triplet}" ] && [ -d "/usr/lib/${target_triplet}" ]; then
    rice_rust_env="${rice_rust_env:-$(printf '%s' "${rust_target}" | tr 'a-z-' 'A-Z_')}"
    rice_rust_lower="${rice_rust_lower:-$(printf '%s' "${rust_target}" | tr '-' '_')}"
    _rice_cflags_var="CFLAGS_${rice_rust_lower}"
    _rice_prev_cflags="${!_rice_cflags_var:-}"
    export "${rice_rust_env}_OPENSSL_LIB_DIR=/usr/lib/${target_triplet}"
    export "${rice_rust_env}_OPENSSL_INCLUDE_DIR=/usr/include"
    export "CFLAGS_${rice_rust_lower}=-I/usr/include -I/usr/include/${target_triplet}${_rice_prev_cflags:+ ${_rice_prev_cflags}}"
    echo "Cross build: rice-proto openssl-sys wired to target OpenSSL (/usr/lib/${target_triplet} + multiarch include ${target_triplet})"
  fi
fi

if ! cargo cinstall "${cinstall_args[@]}"; then
  echo "WARN: cargo cinstall rice-proto failed; webrtcbin2 will be skipped" >&2
  cd /
  rm -rf "${TMPDIR}"
  exit 0
fi

ldconfig 2>/dev/null || true
if PKG_CONFIG_PATH="${LIBDIR}/pkgconfig${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}" pkg-config --exists rice-proto 2>/dev/null; then
  echo "rice-proto $(PKG_CONFIG_PATH="${LIBDIR}/pkgconfig" pkg-config --modversion rice-proto 2>/dev/null) installed to ${PREFIX} (webrtcbin2 enabled)"
else
  echo "WARN: rice-proto.pc not found after install; webrtcbin2 may be skipped" >&2
fi

# Dockerfile.media copies /opt/gstreamer but not /usr/local/lib, and a hard COPY would break when this build skips.
_gst_prefix="${GSTREAMER_PREFIX:-/opt/gstreamer}"
if ls "${LIBDIR}"/librice-proto.so* >/dev/null 2>&1; then
  mkdir -p "${_gst_prefix}/lib/pkgconfig"
  cp -a "${LIBDIR}"/librice-proto.so* "${_gst_prefix}/lib/" 2>/dev/null || true
  cp -a "${LIBDIR}/pkgconfig/rice-proto.pc" "${_gst_prefix}/lib/pkgconfig/" 2>/dev/null || true
  echo "Mirrored librice-proto into ${_gst_prefix}/lib for the final image"
fi

cd /
rm -rf "${TMPDIR}"
