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

  # Without an explicit target linker, cargo links the target cdylib with the
  # host cc/rust-lld and fails ("<obj> is incompatible with elf64-x86-64"). Point
  # the target triple's linker + C compiler at the cross gcc. Only the
  # target-specific CARGO_TARGET_*/CC_* vars are set, so host-side proc-macros and
  # build scripts keep using the native toolchain. Best-effort: on any miss we
  # fall through to the prior behaviour (cinstall may then fail -> webrtcbin2
  # skipped), so this never turns a soft skip into a hard failure.
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

  # rice-proto pulls in openssl-sys transitively. Its header-expansion probe
  # compiles with the cross gcc, which does NOT search the Debian multiarch dir
  # (/usr/include/<triplet>) where the target's arch-specific opensslconf.h lives
  # -- so the probe dies with "openssl/opensslconf.h: No such file". pkg-config
  # finds the target libssl but its openssl.pc ships EMPTY Cflags (native builds
  # rely on gcc's built-in multiarch search), so it supplies no include path.
  # Wire openssl-sys to the target OpenSSL explicitly and inject BOTH include
  # roots via CFLAGS_<target> (honoured by the cc crate the probe uses). Without
  # this, openssl-sys fails and webrtcbin2 is silently skipped on cross builds.
  # Validated by cross-building rice-proto for arm64 (openssl-sys compiles,
  # rice-proto.pc installs).
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

# Refresh the linker cache and verify pkg-config can resolve it. /usr/local/lib
# and its pkgconfig dir are already on the gstreamer stage's PKG_CONFIG paths.
ldconfig 2>/dev/null || true
if PKG_CONFIG_PATH="${LIBDIR}/pkgconfig${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}" pkg-config --exists rice-proto 2>/dev/null; then
  echo "rice-proto $(PKG_CONFIG_PATH="${LIBDIR}/pkgconfig" pkg-config --modversion rice-proto 2>/dev/null) installed to ${PREFIX} (webrtcbin2 enabled)"
else
  echo "WARN: rice-proto.pc not found after install; webrtcbin2 may be skipped" >&2
fi

# Mirror the runtime lib into GSTREAMER_PREFIX/lib so it reaches the FINAL image.
# rice-proto installs to /usr/local/lib, which Dockerfile.media does NOT copy into
# cross-media (only /opt/gstreamer + a couple of explicit globs are). Because this
# builder is best-effort (exits 0 on failure above), a hard Dockerfile COPY of
# librice-proto* can't be used. Riding the already-copied ${GSTREAMER_PREFIX} tree
# keeps webrtcbin2's librice-proto.so.0 loadable at runtime without a build-break
# risk. Best-effort: only mirrors what was actually built.
_gst_prefix="${GSTREAMER_PREFIX:-/opt/gstreamer}"
if ls "${LIBDIR}"/librice-proto.so* >/dev/null 2>&1; then
  mkdir -p "${_gst_prefix}/lib/pkgconfig"
  cp -a "${LIBDIR}"/librice-proto.so* "${_gst_prefix}/lib/" 2>/dev/null || true
  cp -a "${LIBDIR}/pkgconfig/rice-proto.pc" "${_gst_prefix}/lib/pkgconfig/" 2>/dev/null || true
  echo "Mirrored librice-proto into ${_gst_prefix}/lib for the final image"
fi

cd /
rm -rf "${TMPDIR}"
