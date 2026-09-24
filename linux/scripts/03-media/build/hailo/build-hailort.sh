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
# shellcheck source=linux/scripts/03-media/build/hailo/hailo-build-lib.sh
source "${SCRIPT_DIR}/hailo-build-lib.sh"

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
  HAILO_NESTED_CACHE    carry (default): the nested protobuf build is cached;
                        off: it builds uncached, as before 2026-09-24
  HAILO_PYHAILORT_IPO   off (default): pyhailort links a real module;
                        upstream: upstream's forced LTO, an empty module under lld
EOF
    exit 0
    ;;
esac
hailo_validate_knobs || exit 2

: "${HAILORT_VERSION:?HAILORT_VERSION must be set (versions.env)}"
: "${HAILORT_SOURCE_SHA256:?HAILORT_SOURCE_SHA256 must be set (versions.env)}"
: "${HAILO_PROTOBUF_VERSION:?HAILO_PROTOBUF_VERSION must be set (versions.env)}"
: "${HAILO_PROTOBUF_SHA256:?HAILO_PROTOBUF_SHA256 must be set (versions.env)}"
: "${TAPPAS_VERSION:?TAPPAS_VERSION must be set (versions.env)}"
: "${TAPPAS_SOURCE_SHA256:?TAPPAS_SOURCE_SHA256 must be set (versions.env)}"
: "${HAILO_LIBZMQ_VERSION:?HAILO_LIBZMQ_VERSION must be set (versions.env)}"
: "${HAILO_LIBZMQ_SHA256:?HAILO_LIBZMQ_SHA256 must be set (versions.env)}"
: "${HAILO_CPPZMQ_VERSION:?HAILO_CPPZMQ_VERSION must be set (versions.env)}"
: "${HAILO_CPPZMQ_SHA256:?HAILO_CPPZMQ_SHA256 must be set (versions.env)}"

HAILO_PREFIX="${HAILO_PREFIX:-/opt/hailo}"
WORK="${HAILO_BUILD_ROOT:-/var/cache/hailo-build}"
GSTREAMER_PREFIX="${GSTREAMER_PREFIX:-/opt/gstreamer}"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '[INFO] %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }

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
  mkdir -p "${WORK}"
  HAILORT_SRC="${WORK}/hailort-${HAILORT_VERSION}"
  if [ ! -f "${HAILORT_SRC}/CMakeLists.txt" ]; then
    info "fetching hailo-ai/hailort v${HAILORT_VERSION}"
    download_verified_file \
      "https://github.com/hailo-ai/hailort/archive/refs/tags/v${HAILORT_VERSION}.tar.gz" \
      "${HAILORT_SOURCE_SHA256}" "${WORK}/hailort.tar.gz"
    tar -xf "${WORK}/hailort.tar.gz" -C "${WORK}"
  fi

  # HailoRT's external cmake scripts build from the LITERAL
  # <src>/hailort/external/protobuf-src path — FetchContent's
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

  stage_remaining_externals
}

# HailoRT (master, Hailo-10/15) FetchContent externals for a GSTREAMER build.
# With HAILO_OFFLINE_COMPILATION=ON each source must already sit at the LITERAL
# <src>/hailort/external/<name>-src path its cmake builds from; commits are
# verified after checkout. protobuf (verified tarball) is staged above; libusb,
# tokenizers, slint, montserrat, benchmark and catch2 stay unstaged (their
# features are off). Re-derive from hailort/cmake/external/*.cmake at a bump.
# docs/hailo-support.md
# name|repository|commit
HAILO_EXTERNALS=(
  "cli11|https://github.com/hailo-ai/CLI11.git|242adfdb23957d30e3e56831e474020d0ac6c86c"
  "cpp-httplib|https://github.com/yhirose/cpp-httplib.git|51dee793fec2fa70239f5cf190e165b54803880f"
  "dotwriter|https://github.com/hailo-ai/DotWriter|e5fa8f281adca10dd342b1d32e981499b8681daf"
  "eigen|https://gitlab.com/libeigen/eigen|3147391d946bb4b6c68edd901f2add6ac1f31f8c"
  "json|https://github.com/nlohmann/json.git|9cca280a4d0ccf0c08f47a99aa71d1b0e52f8d03"
  "minja|https://github.com/google/minja|58568621432715b0ed38efd16238b0e7ff36c3ba"
  "readerwriterqueue|https://github.com/cameron314/readerwriterqueue|435e36540e306cac40fcfeab8cc0a22d48464509"
  "spdlog|https://github.com/gabime/spdlog|27cb4c76708608465c413f6d0e6b8d99a4d84302"
  "tl-expected|https://github.com/TartanLlama/expected.git|1770e3559f2f6ea4a5fb4f577ad22aeb30fbd8e4"
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
    # The public v5.4.0 tarball ships no tools/ dir (HAILO_BUILD_TOOLS=ON makes
    # CMake add_subdirectory it and die); hailortcli is built unconditionally.
    -DHAILO_BUILD_TOOLS=OFF
    -DHAILO_BUILD_EXAMPLES=OFF
    -DHAILO_OFFLINE_COMPILATION=ON
    -DFETCHCONTENT_SOURCE_DIR_PROTOBUF="${HAILO_PROTOBUF_SRC}"
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
  # The configure itself builds protobuf, under `env -i`. docs/hailo-support.md#the-nested-build-cache-and-pyhailort-two-switches
  PKG_CONFIG_PATH="$(gst_pkgconfig_dir):${PKG_CONFIG_PATH:-}" \
    hailo_nested_configure hailort-configure "${HAILORT_SRC}/hailort/external/protobuf-build" \
      "${HAILORT_SRC}/hailort/cmake/execute_cmake.cmake" \
      -S "${HAILORT_SRC}" -B "${build_dir}" -G Ninja "${cmake_opts[@]}" \
    || die "HailoRT configure failed"

  local jobs mark
  jobs="$(compute_cpp_heavy_jobs "")"
  mark="$(hailo_cache_mark "${CMAKE_CXX_COMPILER_LAUNCHER:-}")"
  info "building HailoRT (jobs=${jobs})"
  cmake --build "${build_dir}" -j "${jobs}"
  hailo_cache_report hailort-build "${CMAKE_CXX_COMPILER_LAUNCHER:-}" "${mark}"
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

# pyhailort ships from the platform/ directory as a scikit-build-core project
# (distribution `hailort`, import `hailo_platform`), built against the HailoRT
# just installed. Upstream declares requires-python <3.14 while the image runs
# 3.14, so the install relaxes that metadata and PROVES the import — a failure
# is reported, never hidden. docs/hailo-support.md
build_pyhailort() {
  local platform_dir="${HAILORT_SRC}/hailort/libhailort/bindings/python/platform"
  [ -d "${platform_dir}" ] || { warn "pyhailort packaging dir absent; skipping"; return 0; }
  local wheel_dir="${HAILO_PREFIX}/wheels" ipo mark w
  ipo="$(hailo_pyhailort_ipo_mode)" || exit 2
  hailo_pyhailort_ipo "${ipo}" "${platform_dir}/../src/CMakeLists.txt" \
    || die "pyhailort: cannot apply HAILO_PYHAILORT_IPO=${ipo}"
  mkdir -p "${wheel_dir}"
  info "building the pyhailort wheel (scikit-build-core)"
  # pip refuses to even BUILD a wheel whose project rejects the interpreter
  # (upstream: <3.14; the image runs 3.14), so relax the cached source's
  # metadata first; the built wheel's copy is relaxed again at install time.
  sed -i 's/^requires-python = .*/requires-python = ">=3.10"/' "${platform_dir}/pyproject.toml"
  python3 -m pip install --quiet --disable-pip-version-check \
    "scikit-build-core>=0.10" "pybind11>=2.13.6,<3" \
    || die "could not install the pyhailort build backend"
  # pip-installed pybind11 lives in site-packages, which find_package() does not
  # search — without the cmakedir the extension silently builds as a stub (a
  # two-second wheel with no PyInit symbol).
  local pybind_dir
  pybind_dir="$(python3 -m pybind11 --cmakedir 2>/dev/null || true)"
  [ -n "${pybind_dir}" ] || die "pybind11 --cmakedir produced nothing; the pyhailort wheel would be a stub"
  mark="$(hailo_cache_mark "${CMAKE_CXX_COMPILER_LAUNCHER:-}")"
  # Twelve -O3 pybind11 TUs: capped like every heavy C++ build here, never ninja's nproc.
  CMAKE_BUILD_PARALLEL_LEVEL="$(compute_cpp_heavy_jobs "")" \
  CMAKE_ARGS="-DLIBHAILORT_PATH=${HAILO_PREFIX}/lib/libhailort.so -DHAILORT_INCLUDE_DIR=${HAILO_PREFIX}/include -Dpybind11_DIR=${pybind_dir}" \
    python3 -m pip wheel --no-build-isolation --no-deps \
      --wheel-dir "${wheel_dir}" "${platform_dir}" \
    || die "pyhailort wheel build failed"
  hailo_cache_report pyhailort "${CMAKE_CXX_COMPILER_LAUNCHER:-}" "${mark}"
  for w in "${wheel_dir}"/hailort-*.whl; do
    [ -e "${w}" ] || continue
    info "pyhailort wheel: $(basename "${w}")"
    hailo_check_pyext "${w}" "${TARGET_ARCH:-amd64}" "${ipo}" \
      || die "pyhailort wheel $(basename "${w}") carries no working module (HAILO_PYHAILORT_IPO=upstream builds it as upstream does)"
  done
}

install_pyhailort() {
  local wheel ipo out so
  ipo="$(hailo_pyhailort_ipo_mode)" || exit 2
  wheel="$(ls -1 "${HAILO_PREFIX}/wheels"/hailort-*.whl 2>/dev/null | head -1 || true)"
  if [ -z "${wheel}" ]; then
    # off promises a checked module in /opt/venv, so nothing to install is fatal there.
    [ "${ipo}" = upstream ] || die "pyhailort: no hailort-*.whl in ${HAILO_PREFIX}/wheels to install (HAILO_PYHAILORT_IPO=upstream skips it)"
    warn "pyhailort: no hailort-*.whl in ${HAILO_PREFIX}/wheels; nothing installed into /opt/venv"
    return 0
  fi
  [ -x /opt/venv/bin/python ] || { info "no /opt/venv; pyhailort wheel stays staged at ${wheel}"; return 0; }

  # The pyproject sed above already relaxed Requires-Python before the build,
  # so the wheel installs as-is — proven; a zip-rewrite of the metadata only
  # corrupted it once. Then PROVE the import under the image's 3.14.
  if out="$(uv pip install --python /opt/venv/bin/python --no-deps --reinstall "${wheel}" 2>&1)"; then
    # The installed bytes are what ships: check them, not only the wheel.
    so="$(/opt/venv/bin/python -c 'import sysconfig; print(sysconfig.get_paths()["platlib"])' 2>/dev/null || true)"
    so="$(compgen -G "${so:-/nonexistent}/hailo_platform/pyhailort/_pyhailort*.so" | head -1 || true)"
    hailo_check_pyext "${so:-/opt/venv/<no _pyhailort*.so>}" "${TARGET_ARCH:-amd64}" "${ipo}" \
      || die "pyhailort in /opt/venv carries no working extension module"
    if /opt/venv/bin/python -c 'import hailo_platform' >/dev/null 2>&1; then
      info "pyhailort installed into /opt/venv and imports"
    else
      warn "pyhailort installed but 'import hailo_platform' fails on Python 3.14 (upstream declares <3.14)"
    fi
  else
    printf '%s\n' "${out}" | tail -n 20 >&2
    [ "${ipo}" = upstream ] \
      || die "pyhailort: installing $(basename "${wheel}") into /opt/venv failed, so the module that ships is unchecked (HAILO_PYHAILORT_IPO=upstream only warns)"
    warn "pyhailort wheel staged at ${wheel}; install into /opt/venv failed"
  fi
}

# TAPPAS's core/hailo meson build compiles against header-only libraries that
# upstream clones into core/open_source/ from BRANCHES (rapidjson: master). This
# list pins every one to a commit, verified after checkout. dest = the
# open_source/ subdir; subdir = the path inside the repo that holds the headers.
# name|repository|commit|dest|subdir|sentinel — the sentinel is a header only
# this external provides, because xtensor and xtl SHARE xtensor_stack/base and
# a dest-level "non-empty" guard skips the second one.
TAPPAS_EXTERNALS=(
  "xtensor|https://github.com/xtensor-stack/xtensor.git|825c0fd8a465049c06ad89fa3911b342dbffcabf|xtensor_stack/base|include|xtensor/xarray.hpp"
  "xtl|https://github.com/xtensor-stack/xtl.git|46f8a9390db2c52aaf41de8f93ed0dab97af012d|xtensor_stack/base|include|xtl/xsequence.hpp"
  "cxxopts|https://github.com/jarro2783/cxxopts.git|c74846a891b3cc3bfa992d588b1295f528d43039|cxxopts|include|cxxopts.hpp"
  "pybind11|https://github.com/pybind/pybind11.git|a2e59f0e7065404b44dfe92a28aca47ba1378dc4|pybind11|include|pybind11/pybind11.h"
  "rapidjson|https://github.com/Tencent/rapidjson.git|24b5e7a8b27f42fa16b96fc70aade9106cf7102f|rapidjson|include|rapidjson/document.h"
  "catch2|https://github.com/catchorg/Catch2.git|c4e3767e265808590986d5db6ca1b5532a7f3d13|catch2|single_include/catch2|catch2/catch.hpp"
)

fetch_tappas() {
  TAPPAS_SRC="${WORK}/tappas-${TAPPAS_VERSION}"
  if [ ! -f "${TAPPAS_SRC}/core/hailo/meson.build" ]; then
    info "fetching hailo-ai/tappas v${TAPPAS_VERSION}"
    download_verified_file \
      "https://github.com/hailo-ai/tappas/archive/refs/tags/v${TAPPAS_VERSION}.tar.gz" \
      "${TAPPAS_SOURCE_SHA256}" "${WORK}/tappas.tar.gz"
    tar -xf "${WORK}/tappas.tar.gz" -C "${WORK}"
  fi

  local spec name url commit dest subdir sentinel src
  for spec in "${TAPPAS_EXTERNALS[@]}"; do
    IFS='|' read -r name url commit dest subdir sentinel <<<"${spec}"
    if [ -f "${TAPPAS_SRC}/core/open_source/${dest}/${sentinel}" ]; then
      continue
    fi
    info "staging TAPPAS external ${name} @ ${commit:0:10}"
    src="${WORK}/tappas-ext-${name}"
    rm -rf "${src}"
    git clone --quiet --filter=blob:none --no-checkout "${url}" "${src}" \
      || git clone --quiet --no-checkout "${url}" "${src}"
    git -C "${src}" checkout --quiet "${commit}"
    [ "$(git -C "${src}" rev-parse HEAD)" = "${commit}" ] \
      || die "TAPPAS external ${name} is not ${commit}"
    mkdir -p "${TAPPAS_SRC}/core/open_source/${dest}"
    cp -r "${src}/${subdir}/." "${TAPPAS_SRC}/core/open_source/${dest}/"
  done
}

# TAPPAS's hailoexportzmq/hailoimportzmq elements need libzmq, and the runtime
# image's apt lists are unusable — build it into the Hailo prefix (MPL-2.0).
build_libzmq() {
  local src="${WORK}/libzmq-${HAILO_LIBZMQ_VERSION}" build="${WORK}/libzmq-build"
  if [ -f "${HAILO_PREFIX}/lib/pkgconfig/libzmq.pc" ]; then
    info "libzmq already installed"
    return 0
  fi
  if [ ! -f "${src}/CMakeLists.txt" ]; then
    info "fetching libzmq v${HAILO_LIBZMQ_VERSION}"
    download_verified_file \
      "https://github.com/zeromq/libzmq/releases/download/v${HAILO_LIBZMQ_VERSION}/zeromq-${HAILO_LIBZMQ_VERSION}.tar.gz" \
      "${HAILO_LIBZMQ_SHA256}" "${WORK}/zeromq.tar.gz"
    mkdir -p "${src}"
    tar -xf "${WORK}/zeromq.tar.gz" -C "${src}" --strip-components=1
  fi
  rm -rf "${build}"
  info "building libzmq"
  local mark
  mark="$(hailo_cache_mark "${CMAKE_CXX_COMPILER_LAUNCHER:-}")"
  cmake -S "${src}" -B "${build}" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="${HAILO_PREFIX}" \
    -DBUILD_TESTS=OFF -DWITH_DOCS=OFF -DENABLE_CPACK=OFF -DBUILD_SHARED=ON >/dev/null \
    || die "libzmq configure failed"
  cmake --build "${build}" -j "$(compute_cpp_heavy_jobs "")" || die "libzmq build failed"
  hailo_cache_report libzmq "${CMAKE_CXX_COMPILER_LAUNCHER:-}" "${mark}"
  cmake --install "${build}" || die "libzmq install failed"

  # libzmq ships the C API only; TAPPAS's zmq elements include the C++ header
  # `zmq.hpp`, which lives in cppzmq (header-only, MIT).
  info "installing cppzmq v${HAILO_CPPZMQ_VERSION}"
  download_verified_file \
    "https://github.com/zeromq/cppzmq/archive/refs/tags/v${HAILO_CPPZMQ_VERSION}.tar.gz" \
    "${HAILO_CPPZMQ_SHA256}" "${WORK}/cppzmq.tar.gz"
  local cppzmq_dir="${WORK}/cppzmq-${HAILO_CPPZMQ_VERSION}"
  rm -rf "${cppzmq_dir}"
  mkdir -p "${cppzmq_dir}"
  tar -xf "${WORK}/cppzmq.tar.gz" -C "${cppzmq_dir}" --strip-components=1
  install -D -m 0644 "${cppzmq_dir}/zmq.hpp" "${HAILO_PREFIX}/include/zmq.hpp"
  [ -f "${cppzmq_dir}/zmq_addon.hpp" ] && install -D -m 0644 "${cppzmq_dir}/zmq_addon.hpp" "${HAILO_PREFIX}/include/zmq_addon.hpp"
  return 0
}

# TAPPAS against the image's GStreamer. Its README's "1.16-1.20" is the TESTED
# matrix; the meson constraint is >= 1.0 and 1.29.2 builds clean (proven
# 2026-09-20). The two non-obvious build-args are load-bearing:
#   - libargs is an ARRAY option: elements must be comma-separated, or only the
#     last survives and every HailoRT header goes missing;
#   - libxtensor/libcxxopts/librapidjson default to a repo-root open_source/,
#     while the sources live under core/open_source/.
build_tappas() {
  local build="${WORK}/tappas-build" triple plugin_dir mark
  rm -rf "${build}"
  info "configuring TAPPAS v${TAPPAS_VERSION} (GStreamer, HailoRT ${HAILORT_VERSION})"
  mark="$(hailo_cache_mark "${CMAKE_CXX_COMPILER_LAUNCHER:-}")"
  PKG_CONFIG_PATH="$(gst_pkgconfig_dir):${HAILO_PREFIX}/lib/pkgconfig:${PKG_CONFIG_PATH:-}" \
    meson setup "${build}" "${TAPPAS_SRC}/core/hailo" \
      --prefix="${TAPPAS_PREFIX:-/opt/tappas}" --buildtype=release \
      -Dlibargs="-I${HAILO_PREFIX}/include,-I${HAILO_PREFIX}/include/gstreamer-1.0/gst/hailo" \
      -Dlibxtensor=../open_source/xtensor_stack/base \
      -Dlibcxxopts=../open_source/cxxopts \
      -Dlibrapidjson=../open_source/rapidjson \
    || die "TAPPAS configure failed"
  info "building TAPPAS"
  ninja -C "${build}" -j "$(compute_cpp_heavy_jobs "")" || die "TAPPAS build failed"
  hailo_cache_report tappas "${CMAKE_CXX_COMPILER_LAUNCHER:-}" "${mark}"
  ninja -C "${build}" install || die "TAPPAS install failed"

  # TAPPAS installs its libraries into the system multiarch dirs (its meson
  # hardcodes libdir) — already on the loader path. Its GStreamer plugin must
  # join the image's GST_PLUGIN_PATH dir, exactly like hailonet.
  triple="$(cross_target_triplet_for_arch "${TARGET_ARCH:-amd64}" 2>/dev/null || printf '%s-linux-gnu' "${TARGET_ARCH:-amd64}")"
  plugin_dir="/usr/lib/${triple}/gstreamer-1.0"
  compgen -G "${plugin_dir}/libgsthailotools.so*" >/dev/null \
    || die "TAPPAS plugin not found under ${plugin_dir}"
  cp -a "${plugin_dir}"/libgsthailotools.so* "${GSTREAMER_PREFIX}/lib/multiarch/gstreamer-1.0/"
  ldconfig
  GST_PLUGIN_PATH="${GSTREAMER_PREFIX}/lib/multiarch/gstreamer-1.0:${GST_PLUGIN_PATH:-}" \
    gst-inspect-1.0 hailotools >/dev/null 2>&1 \
    || die "gst-inspect-1.0 hailotools failed"
  info "TAPPAS plugin loads (hailotools)"
}

fetch_sources
build_hailort
build_pyhailort
normalize_layout
verify_install
install_pyhailort
fetch_tappas
build_libzmq
build_tappas
info "HailoRT ${HAILORT_VERSION} installed at ${HAILO_PREFIX}"
