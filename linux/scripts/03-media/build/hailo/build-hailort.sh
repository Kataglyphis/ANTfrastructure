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

# The cross builder carries these; the runtime image (the native arm64 builder)
# already has cmake/ninja/pkg-config/git and the ssl/zlib headers, and its apt
# lists are not usable — install only what is genuinely missing.
if ! command -v cmake >/dev/null 2>&1 || ! command -v ninja >/dev/null 2>&1 \
   || ! command -v pkg-config >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1 \
   || [ ! -f /usr/include/openssl/ssl.h ] || [ ! -f /usr/include/zlib.h ]; then
  install_deps_preamble cmake ninja-build pkg-config git libssl-dev zlib1g-dev
fi

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

  # HailoRT's external cmake scripts build from the LITERAL
  # <src>/hailort/external/{protobuf,grpc}-src paths — FetchContent's
  # FETCHCONTENT_SOURCE_DIR_* override does not reach execute_cmake, so the
  # sources must sit exactly there.
  HAILO_PROTOBUF_SRC="${HAILORT_SRC}/hailort/external/protobuf-src"
  if [ ! -f "${HAILO_PROTOBUF_SRC}/CMakeLists.txt" ]; then
    info "fetching protobuf v${HAILO_PROTOBUF_VERSION}"
    download_verified_file \
      "https://github.com/protocolbuffers/protobuf/archive/refs/tags/v${HAILO_PROTOBUF_VERSION}.tar.gz" \
      "${HAILO_PROTOBUF_SHA256}" "${WORK}/protobuf.tar.gz"
    mkdir -p "${HAILO_PROTOBUF_SRC}"
    tar -xf "${WORK}/protobuf.tar.gz" -C "${HAILO_PROTOBUF_SRC}" --strip-components=1
  fi

  HAILO_GRPC_SRC="${HAILORT_SRC}/hailort/external/grpc-src"
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

  stage_remaining_externals
}

# HailoRT declares 16 FetchContent externals in hailort/cmake/external/*.cmake,
# each pinned to a commit. With HAILO_OFFLINE_COMPILATION=ON nothing is fetched
# at configure time, so every source must already sit at the LITERAL path its
# cmake builds from (<src>/hailort/external/<name>-src) — FetchContent's
# FETCHCONTENT_SOURCE_DIR_* override does not reach the execute_cmake helpers.
# The commits are verified after checkout, the same contract as the LLVM clone;
# protobuf (verified tarball) and gRPC (tag + submodules) are staged above.
# name|repository|commit — re-derive from the cmake files at a HailoRT bump.
HAILO_EXTERNALS=(
  "benchmark|https://github.com/google/benchmark.git|f91b6b42b1b9854772a90ae9501464a161707d1e"
  "catch2|https://github.com/catchorg/Catch2.git|c4e3767e265808590986d5db6ca1b5532a7f3d13"
  "cli11|https://github.com/hailo-ai/CLI11.git|ae78ac41cf225706e83f57da45117e3e90d4a5b4"
  "cpp-httplib|https://github.com/yhirose/cpp-httplib.git|51dee793fec2fa70239f5cf190e165b54803880f"
  "dotwriter|https://github.com/hailo-ai/DotWriter|e5fa8f281adca10dd342b1d32e981499b8681daf"
  "eigen|https://gitlab.com/libeigen/eigen|3147391d946bb4b6c68edd901f2add6ac1f31f8c"
  "json|https://github.com/ArthurSonzogni/nlohmann_json_cmake_fetchcontent.git|391786c6c3abdd3eeb993a3154f1f2a4cfe137a0"
  "libnpy|https://github.com/llohse/libnpy.git|890ea4fcda302a580e633c624c6a63e2a5d422f6"
  "pevents|https://github.com/neosmart/pevents.git|1209b1fd1bd2e75daab4380cf43d280b90b45366"
  "pybind11|https://github.com/pybind/pybind11.git|a2e59f0e7065404b44dfe92a28aca47ba1378dc4"
  "readerwriterqueue|https://github.com/cameron314/readerwriterqueue|435e36540e306cac40fcfeab8cc0a22d48464509"
  "spdlog|https://github.com/gabime/spdlog|27cb4c76708608465c413f6d0e6b8d99a4d84302"
  "tokenizers|https://github.com/mlc-ai/tokenizers-cpp.git|125d072f52290fa6d2944b3d72ccc937786ec631"
  "xxhash|https://github.com/Cyan4973/xxHash|bbb27a5efb85b92a0486cf361a8635715a53f6ba"
)

stage_remaining_externals() {
  local spec name url commit dir
  for spec in "${HAILO_EXTERNALS[@]}"; do
    IFS='|' read -r name url commit <<<"${spec}"
    dir="${HAILORT_SRC}/hailort/external/${name}-src"
    if [ -d "${dir}" ] && [ -n "$(ls -A "${dir}" 2>/dev/null)" ]; then
      continue
    fi
    info "staging external ${name} @ ${commit:0:10}"
    git clone --quiet --filter=blob:none --no-checkout "${url}" "${dir}" \
      || git clone --quiet --no-checkout "${url}" "${dir}"
    git -C "${dir}" checkout --quiet "${commit}"
    [ "$(git -C "${dir}" rev-parse HEAD)" = "${commit}" ] \
      || die "external ${name} is not ${commit}"
    git -C "${dir}" submodule update --init --recursive --quiet
  done
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

  # The cross-android builder is an amd64 image carrying the TARGET cross
  # toolchain (every cross stage is built on amd64). A bare `gcc` there is the
  # HOST compiler: its driver then hands aarch64 flags to the x86 assembler
  # (`as: unrecognized option '-EL'`), and the image ships no prefixed binutils
  # for it to fall back on. The repo's own cross builds use the LLVM wrappers
  # installed by 02-toolchain/llvm.sh — `clang-<arch>` execs clang with
  # `--target=<triplet> --sysroot=... --gcc-toolchain=<prefix>`, so the
  # integrated assembler needs no binutils at all.
  local target_arch="${TARGET_ARCH:-amd64}" build_arch cc cxx
  build_arch="$(build_arch_oci 2>/dev/null || printf 'amd64')"
  if [ "${target_arch}" != "${build_arch}" ]; then
    cc="$(command -v "clang-${target_arch}")" \
      || die "no clang-${target_arch} wrapper for cross target ${target_arch}"
    cxx="$(command -v "clang++-${target_arch}")" \
      || die "no clang++-${target_arch} wrapper for cross target ${target_arch}"
    cmake_opts+=(-DCMAKE_C_COMPILER="${cc}" -DCMAKE_CXX_COMPILER="${cxx}")
    info "cross toolchain: ${cc} (LLVM wrapper)"
  fi

  append_cmake_cache_linker_args cmake_opts

  rm -rf "${build_dir}"
  # The nested FetchContent builds live beside the sources and survive the
  # top-level clean; a stale cache from an earlier attempt carries a DIFFERENT
  # compiler and poisons the configure (observed as CMake's Ninja/RPATH
  # "not ELF-based" error when a cross-attempt cache met the native build).
  rm -rf "${HAILORT_SRC}/hailort/external"/*-build "${HAILORT_SRC}/hailort/external"/*-install
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
