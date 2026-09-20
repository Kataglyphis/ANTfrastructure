#!/usr/bin/env bash
# Build HailoRT (libhailort + hailortcli + the hailonet GStreamer element) from
# the pinned hailo8 source for the opt-in Hailo variant image.
# Plan and upstream matrix: docs/hailo-support.md § What exists (2026-09-20).
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../core/common.sh"
media_common_init "${SCRIPT_DIR}"

case "${1:-}" in
  -h|--help)
    cat <<'EOF'
Usage: build-hailort.sh

Builds HailoRT for the Hailo-8/8R/8L family (the hailo8 branch) and installs it
to HAILO_PREFIX. protobuf and gRPC are staged from verified sources — upstream's
FetchContent would clone them unpinned at configure time.

Environment:
  HAILO_PREFIX          Install prefix (default: /opt/hailo)
  HAILO_BUILD_ROOT      Work tree (default: /var/cache/hailo-build; cache mount)
  TARGET_ARCH           amd64|arm64 (riscv64 is refused — no HailoRT support)
  GSTREAMER_PREFIX      GStreamer prefix (default: /opt/gstreamer)
EOF
    exit 0
    ;;
esac

: "${HAILORT_VERSION:?HAILORT_VERSION must be set (versions.env)}"
: "${HAILORT_SOURCE_SHA256:?HAILORT_SOURCE_SHA256 must be set (versions.env)}"
: "${HAILO_PROTOBUF_VERSION:?HAILO_PROTOBUF_VERSION must be set (versions.env)}"
: "${HAILO_PROTOBUF_SHA256:?HAILO_PROTOBUF_SHA256 must be set (versions.env)}"
: "${HAILO_GRPC_VERSION:?HAILO_GRPC_VERSION must be set (versions.env)}"
: "${HAILO_GRPC_COMMIT:?HAILO_GRPC_COMMIT must be set (versions.env)}"

HAILO_PREFIX="${HAILO_PREFIX:-/opt/hailo}"
WORK="${HAILO_BUILD_ROOT:-/var/cache/hailo-build}"
GSTREAMER_PREFIX="${GSTREAMER_PREFIX:-/opt/gstreamer}"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '[INFO] %s\n' "$*"; }

# HailoRT ships no riscv64 support at any version; the variant is amd64/arm64.
[ "${TARGET_ARCH:-amd64}" != "riscv64" ] || die "Hailo is not supported on riscv64"

install_deps_preamble cmake ninja-build pkg-config git libssl-dev zlib1g-dev

# The media GStreamer is a multiarch install: .pc files live under
# lib/<triple>/pkgconfig, not lib/pkgconfig.
gst_pkgconfig_dir() {
  local d
  for d in "${GSTREAMER_PREFIX}"/lib/*/pkgconfig; do
    [ -d "${d}" ] && { printf '%s' "${d}"; return 0; }
  done
  die "no GStreamer pkg-config dir under ${GSTREAMER_PREFIX}/lib/*/pkgconfig"
}

fetch_sources() {
  HAILORT_SRC="${WORK}/hailort-${HAILORT_VERSION}"
  if [ ! -f "${HAILORT_SRC}/CMakeLists.txt" ]; then
    info "fetching hailo-ai/hailort v${HAILORT_VERSION}"
    download_verified_file \
      "https://github.com/hailo-ai/hailort/archive/refs/tags/v${HAILORT_VERSION}.tar.gz" \
      "${HAILORT_SOURCE_SHA256}" "${WORK}/hailort.tar.gz"
    tar -xf "${WORK}/hailort.tar.gz" -C "${WORK}"
  fi

  HAILO_PROTOBUF_SRC="${WORK}/protobuf-${HAILO_PROTOBUF_VERSION}"
  if [ ! -f "${HAILO_PROTOBUF_SRC}/CMakeLists.txt" ]; then
    info "fetching protobuf v${HAILO_PROTOBUF_VERSION}"
    download_verified_file \
      "https://github.com/protocolbuffers/protobuf/archive/refs/tags/v${HAILO_PROTOBUF_VERSION}.tar.gz" \
      "${HAILO_PROTOBUF_SHA256}" "${WORK}/protobuf.tar.gz"
    tar -xf "${WORK}/protobuf.tar.gz" -C "${WORK}"
  fi

  HAILO_GRPC_SRC="${WORK}/grpc-${HAILO_GRPC_VERSION}"
  if [ ! -f "${HAILO_GRPC_SRC}/CMakeLists.txt" ]; then
    # A tarball is unusable here: gRPC's C++ build needs its submodules
    # (abseil among them), which GitHub archives omit. Clone at the tag, verify
    # the commit, then take the submodules at their gitlink-pinned commits.
    info "cloning grpc v${HAILO_GRPC_VERSION}"
    git clone --depth 1 --branch "v${HAILO_GRPC_VERSION}" \
      https://github.com/grpc/grpc.git "${HAILO_GRPC_SRC}"
    [ "$(git -C "${HAILO_GRPC_SRC}" rev-parse HEAD)" = "${HAILO_GRPC_COMMIT}" ] \
      || die "grpc v${HAILO_GRPC_VERSION} is not ${HAILO_GRPC_COMMIT}"
    git -C "${HAILO_GRPC_SRC}" submodule update --init --recursive
  fi
}

build_hailort() {
  local build_dir="${WORK}/hailort-build-${TARGET_ARCH:-amd64}"
  local -a cmake_opts=(
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_INSTALL_PREFIX="${HAILO_PREFIX}"
    -DHAILO_BUILD_GSTREAMER=ON
    -DHAILO_BUILD_TOOLS=ON
    -DHAILO_BUILD_EXAMPLES=OFF
    -DHAILO_OFFLINE_COMPILATION=ON
    -DFETCHCONTENT_SOURCE_DIR_PROTOBUF="${HAILO_PROTOBUF_SRC}"
    -DFETCHCONTENT_SOURCE_DIR_GRPC="${HAILO_GRPC_SRC}"
  )
  append_cmake_cache_linker_args cmake_opts

  rm -rf "${build_dir}"
  info "configuring HailoRT (GStreamer element ON, offline externals)"
  PKG_CONFIG_PATH="$(gst_pkgconfig_dir):${PKG_CONFIG_PATH:-}" \
    cmake -S "${HAILORT_SRC}" -B "${build_dir}" -G Ninja "${cmake_opts[@]}"

  local jobs
  jobs="$(compute_cpp_heavy_jobs "")"
  info "building HailoRT (jobs=${jobs})"
  cmake --build "${build_dir}" -j "${jobs}"
  cmake --install "${build_dir}"
}

normalize_layout() {
  # The plugin installs under lib/<triple>-linux-gnu/gstreamer-1.0 inside the
  # prefix; the image points GST_PLUGIN_PATH at one fixed dir instead.
  mkdir -p "${HAILO_PREFIX}/lib/gstreamer-1.0"
  local plugin
  plugin="$(find "${HAILO_PREFIX}" -name 'gsthailo.so' -o -name 'libgsthailo.so' 2>/dev/null | head -1)"
  [ -n "${plugin}" ] || die "hailonet plugin not found after install"
  cp -a "${plugin}" "${HAILO_PREFIX}/lib/gstreamer-1.0/gsthailo.so"
  # Keep libhailort on a stable LD_LIBRARY_PATH entry.
  find "${HAILO_PREFIX}" -name 'libhailort.so*' -exec cp -a {} "${HAILO_PREFIX}/lib/" \; 2>/dev/null || true
}

verify_install() {
  LD_LIBRARY_PATH="${HAILO_PREFIX}/lib:${LD_LIBRARY_PATH:-}" \
    "${HAILO_PREFIX}/bin/hailortcli" --version >/dev/null 2>&1 \
    || die "hailortcli does not run after install"
  GST_PLUGIN_PATH="${HAILO_PREFIX}/lib/gstreamer-1.0" \
    LD_LIBRARY_PATH="${HAILO_PREFIX}/lib:${LD_LIBRARY_PATH:-}" \
    gst-inspect-1.0 hailonet >/dev/null 2>&1 \
    || die "gst-inspect-1.0 hailonet failed"
  info "hailortcli runs and the hailonet element loads"
}

fetch_sources
build_hailort
normalize_layout
verify_install
info "HailoRT ${HAILORT_VERSION} installed at ${HAILO_PREFIX}"
