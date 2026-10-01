#!/usr/bin/env bash
# DeepStream for the nvidia variant: docs/linux-accelerator-images.md#deepstream-nvidia-variant
set -euo pipefail

DS_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DS_OPT="${DS_OPT:-/opt/nvidia/deepstream}"
DS_REPO_URL="${DS_REPO_URL:-https://github.com/NVIDIA/DeepStream.git}"
DS_RELEASE_URL="${DS_RELEASE_URL:-https://github.com/NVIDIA/DeepStream/releases/download}"
DS_TRT_REPO_URL="${DS_TRT_REPO_URL:-https://developer.download.nvidia.com/compute/cuda/repos}"

# Built by NVIDIA's build/build.sh but left out here, each with the reason it cannot build or load in this image.
DS_EXCLUDED=(
  "src/utils/nvdsinferserver|Triton: needs the Triton server SDK and libtritonserver.so, which the image does not ship"
  "src/gst-plugins/gst-nvinferserver|Triton: links libnvds_infer_server.so (src/utils/nvdsinferserver)"
  "src/utils/nvds_msgapi/azure_protocol_adaptor/device_client|Azure IoT: needs azure-iot-sdk-c, which the image does not ship"
  "src/utils/nvds_msgapi/azure_protocol_adaptor/module_client|Azure IoT: needs azure-iot-sdk-c, which the image does not ship"
  "src/gst-plugins/gst-nvdsudp|needs NVIDIA's Rivermax SDK (login-gated); upstream build.sh skips it too"
  "src/gst-plugins/gst-dsexample-cuda|an example that needs OpenCV's CUDA modules; upstream build.sh skips it too"
)

# Distro libraries the runtime .deb and the built components load; measured with ldd + dpkg -S on 2026-10-01.
DS_RUNTIME_PACKAGES=(
  libyaml-cpp0.8 libmosquitto1 libprotobuf32t64 librdkafka1 librabbitmq4 libhiredis1.1.0
  libcjson1 libjansson4 libjsoncpp26 libjson-glib-1.0-0 libcurl3t64-gnutls
  libavahi-compat-libdnssd1 libv4l-0t64 libjpeg-turbo8 libuuid1
)

DS_BUILD_PACKAGES=(
  libyaml-cpp-dev libjson-glib-dev uuid-dev libjpeg-turbo8-dev libmosquitto-dev libjansson-dev
  libssl-dev libcurl4-openssl-dev libjsoncpp-dev libcjson-dev libhiredis-dev librdkafka-dev
  librabbitmq-dev protobuf-compiler libprotobuf-dev nlohmann-json3-dev libgles-dev libegl-dev
)

# shellcheck source=deepstream-verify.sh
source "${DS_SCRIPT_DIR}/deepstream-verify.sh"

ds_log() { printf '[deepstream] %s\n' "$*"; }
ds_die() { printf '[deepstream] ERROR: %s\n' "$*" >&2; exit 1; }

ds_core_dir() {
  local d
  for d in "${DS_CORE_DIR:-}" "${DS_SCRIPT_DIR}/../01-core" /opt/scripts/core; do
    if [ -n "${d}" ] && [ -f "${d}/versions.env" ] && [ -f "${d}/downloads.sh" ]; then
      printf '%s' "${d}"; return 0
    fi
  done
  return 1
}

# Prints every pin that is missing or malformed; empty output means all are usable.
ds_pin_problems() {
  local v
  [[ "${DEEPSTREAM_VERSION:-}" =~ ^([0-9]+\.){2}[0-9]+$ ]] || echo "DEEPSTREAM_VERSION='${DEEPSTREAM_VERSION:-}' is not X.Y.Z"
  [[ "${DEEPSTREAM_TENSORRT_VERSION:-}" =~ ^10(\.[0-9]+){3}$ ]] \
    || echo "DEEPSTREAM_TENSORRT_VERSION='${DEEPSTREAM_TENSORRT_VERSION:-}' is not a TensorRT 10 version"
  [[ "${DEEPSTREAM_TENSORRT_CUDA:-}" =~ ^[0-9]+\.[0-9]+$ ]] || echo "DEEPSTREAM_TENSORRT_CUDA='${DEEPSTREAM_TENSORRT_CUDA:-}' is not X.Y"
  [[ "${DEEPSTREAM_TENSORRT_REPO:-}" =~ ^ubuntu[0-9]{4}$ ]] || echo "DEEPSTREAM_TENSORRT_REPO='${DEEPSTREAM_TENSORRT_REPO:-}' is not ubuntuNNNN"
  for v in DEEPSTREAM_COMMIT DEEPSTREAM_CIVETWEB_COMMIT DEEPSTREAM_PROMETHEUS_CPP_COMMIT DEEPSTREAM_OPENTELEMETRY_CPP_COMMIT; do
    [[ "${!v:-}" =~ ^[0-9a-f]{40}$ ]] || echo "${v}='${!v:-}' is not a 40-hex commit"
  done
  for v in DEEPSTREAM_BINARIES_AMD64_SHA256 DEEPSTREAM_TRT_LIBNVINFER10_SHA256 DEEPSTREAM_TRT_LIBNVINFER_PLUGIN10_SHA256 \
           DEEPSTREAM_TRT_LIBNVONNXPARSERS10_SHA256 DEEPSTREAM_TRT_LIBNVINFER_HEADERS_DEV_SHA256 \
           DEEPSTREAM_TRT_LIBNVINFER_HEADERS_PLUGIN_DEV_SHA256 DEEPSTREAM_TRT_LIBNVONNXPARSERS_DEV_SHA256; do
    [[ "${!v:-}" =~ ^[0-9a-f]{64}$ ]] || echo "${v}='${!v:-}' is not a 64-hex sha256"
  done
  return 0
}

ds_load_pins() {
  local core problems
  core="$(ds_core_dir)" || ds_die "no 01-core dir with versions.env and downloads.sh (set DS_CORE_DIR)"
  # common.sh loads versions.env and downloads.sh, and owns the compiler-cache resolver.
  # shellcheck disable=SC1091
  source "${core}/common.sh"
  problems="$(ds_pin_problems)"
  [ -z "${problems}" ] || ds_die "refusing to build with unusable pins:"$'\n'"${problems}"
}

# Refuses a distro GStreamer: /opt/gstreamer must stay the only copy.
ds_apt_install() {
  local pulled
  apt-get update -qq
  pulled="$(apt-get install -s -y --no-install-recommends "$@" | awk '/^Inst /{print $2}' | grep -E 'gstreamer|^libgst' || true)"
  [ -z "${pulled}" ] || ds_die "these packages would install a distro GStreamer: ${pulled//$'\n'/ }"
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
}

ds_root() { printf '%s/deepstream-%s' "${DS_OPT}" "${DEEPSTREAM_VERSION%.*}"; }
ds_trt_prefix() { printf '%s/tensorrt-%s' "${DS_OPT}" "${DEEPSTREAM_TENSORRT_VERSION}"; }

# amd64 only until CON42 phase 7: the arm64 runtime is Jetson's, and SBSA exists only inside NVIDIA's container.
ds_arch_problem() {
  local arch="${1:-}"
  case "${arch}" in
    amd64) return 0 ;;
    arm64) echo "arm64 has no DeepStream route in this image yet (Jetson and SBSA are separate targets; CON42 phase 7)" ;;
    *) echo "DeepStream ships no runtime for '${arch:-unknown}'" ;;
  esac
}

# Refuses a DeepStream build outside the nvidia variant: the runtime needs CUDA, and :latest must never carry it.
ds_gate_problem() {
  [ "${ENABLE_NVIDIA:-false}" = "true" ] || { echo "ENABLE_DEEPSTREAM=true needs ENABLE_NVIDIA=true (the nvidia variant)"; return 0; }
  [ -x "${CUDA_HOME:-/usr/local/cuda}/bin/nvcc" ] || echo "no nvcc at ${CUDA_HOME:-/usr/local/cuda}/bin/nvcc"
  return 0
}

ds_cuda_ver() {
  "${CUDA_HOME:-/usr/local/cuda}/bin/nvcc" --version | sed -n 's/.*release \([0-9][0-9]*\.[0-9][0-9]*\),.*/\1/p'
}

# ds_fetch <url> <sha256> <dest>: download_verified_file, reusing a verified copy from DS_DOWNLOAD_CACHE.
ds_fetch() {
  local url="$1" sha="$2" dest="$3" cached=""
  [ -n "${DS_DOWNLOAD_CACHE:-}" ] && cached="${DS_DOWNLOAD_CACHE}/${sha}-${url##*/}"
  if [ -n "${cached}" ] && [ -f "${cached}" ] && printf '%s  %s\n' "${sha}" "${cached}" | sha256sum -c - >/dev/null 2>&1; then
    cp "${cached}" "${dest}"; return 0
  fi
  download_verified_file "${url}" "${sha}" "${dest}"
  if [ -n "${cached}" ]; then mkdir -p "${DS_DOWNLOAD_CACHE}" && cp "${dest}" "${cached}"; fi
  return 0
}

ds_stage_runtime_deb() {
  local tmp="$1" deb asset
  asset="deepstream-binaries-x86_${DEEPSTREAM_VERSION}_amd64.deb"
  deb="${tmp}/${asset}"
  ds_fetch "${DS_RELEASE_URL}/v${DEEPSTREAM_VERSION}/${asset}" "${DEEPSTREAM_BINARIES_AMD64_SHA256}" "${deb}"
  mkdir -p "${tmp}/runtime"
  dpkg-deb -x "${deb}" "${tmp}/runtime"
  rm -f "${deb}"
  local unpacked="${tmp}/runtime${DS_OPT}/deepstream-${DEEPSTREAM_VERSION%.*}"
  [ -f "${unpacked}/LicenseAgreement.pdf" ] || ds_die "the runtime .deb has no ${unpacked#"${tmp}"/runtime}/LicenseAgreement.pdf"
  mkdir -p "${DS_OPT}"
  rm -rf "$(ds_root)"
  mv "${unpacked}" "$(ds_root)"
  ln -sfn "$(basename "$(ds_root)")" "${DS_OPT}/deepstream"
  ds_log "runtime ${asset} -> $(ds_root)"
}

# "<package> <sha256>" per TensorRT 10 deb: the runtime libraries and the headers the sources compile against.
ds_trt_debs() {
  printf '%s %s\n' \
    libnvinfer10 "${DEEPSTREAM_TRT_LIBNVINFER10_SHA256}" \
    libnvinfer-plugin10 "${DEEPSTREAM_TRT_LIBNVINFER_PLUGIN10_SHA256}" \
    libnvonnxparsers10 "${DEEPSTREAM_TRT_LIBNVONNXPARSERS10_SHA256}" \
    libnvinfer-headers-dev "${DEEPSTREAM_TRT_LIBNVINFER_HEADERS_DEV_SHA256}" \
    libnvinfer-headers-plugin-dev "${DEEPSTREAM_TRT_LIBNVINFER_HEADERS_PLUGIN_DEV_SHA256}" \
    libnvonnxparsers-dev "${DEEPSTREAM_TRT_LIBNVONNXPARSERS_DEV_SHA256}"
}

ds_trt_deb_url() {
  printf '%s/%s/x86_64/%s_%s-1+cuda%s_amd64.deb' "${DS_TRT_REPO_URL}" "${DEEPSTREAM_TENSORRT_REPO}" \
    "$1" "${DEEPSTREAM_TENSORRT_VERSION}" "${DEEPSTREAM_TENSORRT_CUDA}"
}

ds_stage_tensorrt() {
  local tmp="$1" prefix pkg sha deb x="${1}/trt"
  prefix="$(ds_trt_prefix)"
  mkdir -p "${x}"
  while read -r pkg sha; do
    deb="${tmp}/${pkg}.deb"
    ds_fetch "$(ds_trt_deb_url "${pkg}")" "${sha}" "${deb}"
    dpkg-deb -x "${deb}" "${x}"
    rm -f "${deb}"
  done < <(ds_trt_debs)
  rm -rf "${prefix}"
  mkdir -p "${prefix}/lib" "${prefix}/include" "${prefix}/doc"
  cp -a "${x}/usr/include/x86_64-linux-gnu/." "${prefix}/include/"
  find "${x}/usr/lib/x86_64-linux-gnu" -maxdepth 1 \( -name '*.so*' \) -exec cp -a {} "${prefix}/lib/" \;
  cp -a "${x}/usr/share/doc/." "${prefix}/doc/"
  local lib
  for lib in libnvinfer libnvinfer_plugin libnvonnxparser; do
    [ -e "${prefix}/lib/${lib}.so.10" ] || ds_die "TensorRT ${DEEPSTREAM_TENSORRT_VERSION}: no ${lib}.so.10 in the debs"
    ln -sfn "${lib}.so.10" "${prefix}/lib/${lib}.so"
  done
  rm -rf "${x}"
  ds_log "TensorRT ${DEEPSTREAM_TENSORRT_VERSION} -> ${prefix}"
}

# The tag's tree is ~90 MB at depth 1; sources/includes is the full SDK's layout, which ds3d's lidarsource includes from.
ds_fetch_sources() {
  local dir="$1"
  ds_clone_dep "${DS_REPO_URL}" "${DEEPSTREAM_COMMIT}" "${dir}"
  rm -rf "$(ds_root)/sources"; mkdir -p "$(ds_root)/sources"
  cp -a "${dir}/includes" "$(ds_root)/sources/includes"
  cp "${dir}/LICENSE" "$(ds_root)/sources/LICENSE"
}

ds_excluded_reason() {
  local dir="${1%/}" e
  for e in "${DS_EXCLUDED[@]}"; do
    [ "${e%%|*}" = "${dir}" ] && { printf '%s' "${e#*|}"; return 0; }
  done
  return 1
}

# build.sh's order: gst-utils, utils (+ msgapi adaptors, ds3d), gst-plugins, then the plugins' helper libraries.
ds_components() {
  local src="$1" d
  local -a order=(src/gst-utils/gstnvcustomhelper src/gst-utils/gst-nvdssr src/gst-utils/gstnvdscustomhelper src/utils/nvds_rest_server)
  while IFS= read -r d; do order+=("${d}"); done < <(
    cd "${src}" && LC_ALL=C find src/utils -mindepth 1 -maxdepth 1 -type d ! -name nvds_rest_server | LC_ALL=C sort
    cd "${src}" && LC_ALL=C find src/utils/nvds_msgapi src/utils/ds3d -mindepth 1 -maxdepth 2 -type d | LC_ALL=C sort
    cd "${src}" && LC_ALL=C find src/gst-plugins -mindepth 1 -maxdepth 1 -type d | LC_ALL=C sort)
  order+=(src/gst-plugins/gst-nvdspreprocess/nvdspreprocess_lib src/gst-plugins/gst-nvdsmetautils/sei_serialization
          src/gst-plugins/gst-nvdsmetautils/audio_metadata_serialization src/gst-plugins/gst-nvdsmetautils/video_metadata_serialization
          src/gst-plugins/gst-nvdspostprocess/postprocesslib_impl src/gst-plugins/gst-nvdsvideotemplate/customlib_impl)
  for d in "${order[@]}"; do
    [ -f "${src}/${d}/Makefile" ] || continue
    ds_excluded_reason "${d}" >/dev/null && continue
    printf '%s\n' "${d}"
  done
}

# GCC 16's libstdc++ no longer includes <cstdint>/<algorithm> transitively, and turns a new warning into an error under -Werror.
ds_write_compat_header() {
  cat > "$1" <<'EOF'
#ifdef __cplusplus
#include <cstdint>
#include <algorithm>
#else
#include <stdint.h>
#endif
EOF
}

# ds_component_compiler <Makefile> <CXX|CC> <compat header>: the Makefile's own compiler plus the GCC 16 fixes; the C++-only flag only where it compiles C++.
ds_component_compiler() {
  local base var="$2"
  base="$(sed -nE "s/^${var}[[:space:]]*[:?]?=[[:space:]]*([^#]*[^#[:space:]]).*/\\1/p" "$1" | head -1)"
  if [ -z "${base}" ]; then
    if [ "${var}" = CXX ]; then base=g++; else base=cc; fi
  fi
  case "${var}:${base%% *}" in
    CXX:gcc|CXX:cc|CC:*) printf '%s%s -include %s' "${DS_CACHE_LAUNCHER:+${DS_CACHE_LAUNCHER} }" "${base}" "$3" ;;
    *) printf '%s%s -include %s -Wno-error=non-c-typedef-for-linkage' "${DS_CACHE_LAUNCHER:+${DS_CACHE_LAUNCHER} }" "${base}" "$3" ;;
  esac
}

# nvstreammux is a static archive gst-nvmultistream2 links, so it is built but not installed, as in build.sh.
ds_build_component() {
  local src="$1" dir="$2" log="$3" cxx cc jobs
  cxx="$(ds_component_compiler "${src}/${dir}/Makefile" CXX "${DS_COMPAT_H}")"
  cc="$(ds_component_compiler "${src}/${dir}/Makefile" CC "${DS_COMPAT_H}")"
  jobs="${DS_JOBS:-$(nproc)}"
  local -a mk=(make -C "${src}/${dir}" -j"${jobs}" "CUDA_VER=${DS_CUDA_VER}" "CXX=${cxx}" "CC=${cc}"
               "NVDS_VERSION=${DEEPSTREAM_VERSION%.*}" PROTOBUF_BIN_DIR=/usr/bin)
  if "${mk[@]}" >"${log}" 2>&1 && { [ "${dir}" = src/utils/nvstreammux ] || "${mk[@]}" install >>"${log}" 2>&1; }; then
    return 0
  fi
  tail -n 40 "${log}" >&2
  ds_die "component ${dir} failed to build (log above)"
}

ds_build_components() {
  local src="$1" logdir="$2" dir n=0 trt
  trt="$(ds_trt_prefix)"
  mkdir -p "${logdir}" "$(ds_root)/lib/gst-plugins" "$(ds_root)/bin"
  DS_COMPAT_H="${logdir}/gcc16-compat.h"
  ds_write_compat_header "${DS_COMPAT_H}"
  DS_CUDA_VER="$(ds_cuda_ver)"
  compiler_cache_launcher_env 2>/dev/null || true
  DS_CACHE_LAUNCHER="$(compiler_cache_launcher)" || DS_CACHE_LAUNCHER=""
  [ -n "${DS_CUDA_VER}" ] || ds_die "cannot read the CUDA version from nvcc"
  [ -e "/usr/local/cuda-${DS_CUDA_VER}" ] || ds_die "the Makefiles expect /usr/local/cuda-${DS_CUDA_VER}"
  export CPATH="${trt}/include${CPATH:+:${CPATH}}"
  export LIBRARY_PATH="${trt}/lib:/usr/local/cuda-${DS_CUDA_VER}/lib64:/usr/local/cuda-${DS_CUDA_VER}/lib64/stubs${LIBRARY_PATH:+:${LIBRARY_PATH}}"
  export NVCC_PREPEND_FLAGS="${NVCC_PREPEND_FLAGS:-} -include ${logdir}/gcc16-compat.h"
  # gst-nvvideotestsrc hard-codes /usr/include/gstreamer-1.0 for nvcc; its Makefile appends to this.
  NVCC_CFLAGS="$(pkg-config --cflags-only-I gstreamer-1.0)"
  export NVCC_CFLAGS
  while IFS= read -r dir; do
    ds_build_component "${src}" "${dir}" "${logdir}/$(printf '%s' "${dir}" | tr '/' '_').log"
    n=$((n + 1))
  done < <(ds_components "${src}")
  ds_log "built ${n} components from ${DEEPSTREAM_COMMIT}"
}

# ds_clone_dep <url> <commit> <dir>: clone_or_update_repo fetches a 40-hex ref exactly and fails otherwise.
ds_clone_dep() {
  clone_or_update_repo "$1" "$3" "$2"
  [ "$(git -C "$3" rev-parse HEAD)" = "$2" ] || ds_die "$1 is not at $2"
}

ds_build_rest_server_deps() {
  local w="$1" lib
  lib="$(ds_root)/lib"
  ds_clone_dep https://github.com/civetweb/civetweb.git "${DEEPSTREAM_CIVETWEB_COMMIT}" "${w}/civetweb"
  printf 'CIVETWEB_%s {\n global:\n  *;\n local:\n  duk_*;\n};\n' "${DEEPSTREAM_CIVETWEB_VERSION#v}" > "${w}/civetweb/civetweb.ver"
  make -C "${w}/civetweb" -j"${DS_JOBS:-$(nproc)}" slib WITH_ALL=1 WITH_CPP=1 \
    LDFLAGS="-Wl,--version-script,${w}/civetweb/civetweb.ver" >"${w}/civetweb.log" 2>&1 || { tail -n 30 "${w}/civetweb.log" >&2; ds_die "civetweb failed"; }
  cp -P "${w}/civetweb/libcivetweb.so"* "${lib}/"
  ds_clone_dep https://github.com/jupp0r/prometheus-cpp.git "${DEEPSTREAM_PROMETHEUS_CPP_COMMIT}" "${w}/prometheus-cpp"
  git -C "${w}/prometheus-cpp" submodule update -q --init --recursive --depth 1
  ds_cmake_install "${w}/prometheus-cpp" "${w}/prom" -DENABLE_TESTING=OFF -DENABLE_PUSH=OFF -DENABLE_COMPRESSION=OFF
  cp -P "${w}/prom/install/lib/"libprometheus-cpp-core.so* "${lib}/"
  ds_clone_dep https://github.com/open-telemetry/opentelemetry-cpp.git "${DEEPSTREAM_OPENTELEMETRY_CPP_COMMIT}" "${w}/otel"
  ds_cmake_install "${w}/otel" "${w}/otel-b" -DWITH_OTLP_HTTP=ON -DWITH_OTLP_GRPC=OFF -DWITH_PROMETHEUS=OFF \
    -DBUILD_TESTING=OFF -DWITH_EXAMPLES=OFF -DWITH_BENCHMARK=OFF
  cp -P "${w}/otel-b/install/lib/"libopentelemetry_*.so* "${lib}/"
}

ds_cmake_install() {
  local srcdir="$1" b="$2"; shift 2
  if ! { cmake -S "${srcdir}" -B "${b}/build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON \
           -DCMAKE_INSTALL_PREFIX="${b}/install" -DCMAKE_INSTALL_RPATH='$ORIGIN' -Wno-dev "$@" >"${b}.log" 2>&1 \
         && cmake --build "${b}/build" >>"${b}.log" 2>&1 && cmake --install "${b}/build" >>"${b}.log" 2>&1; }; then
    tail -n 40 "${b}.log" >&2
    ds_die "${srcdir##*/} failed to build"
  fi
}

# gst-plugins/ must hold only plugins: a helper .so there is dlclose()d by the registry scan and crashes the next plugin.
ds_fix_layout() {
  local root="$1" f
  while IFS= read -r f; do
    ds_log "not a GStreamer plugin, moved to lib/: ${f##*/}"
    mv "${f}" "${root}/lib/"
  done < <(dsv_non_plugins "${root}/lib/gst-plugins")
}

ds_build() {
  ds_load_pins
  local problem tmp
  problem="$(ds_arch_problem "$(dpkg --print-architecture)")"; [ -z "${problem}" ] || ds_die "${problem}"
  problem="$(ds_gate_problem)"; [ -z "${problem}" ] || ds_die "${problem}"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/deepstream.XXXXXX")"
  ds_apt_install "${DS_BUILD_PACKAGES[@]}" "${DS_RUNTIME_PACKAGES[@]}"
  ds_stage_runtime_deb "${tmp}"
  ds_stage_tensorrt "${tmp}"
  ds_fetch_sources "${tmp}/src"
  ds_build_rest_server_deps "${tmp}/deps"
  ds_build_components "${tmp}/src" "${tmp}/logs"
  ds_fix_layout "$(ds_root)"
  rm -rf "${tmp}"
  ds_write_trt_ldconf
  DS_ROOT="$(ds_root)" DS_TRT_PREFIX="$(ds_trt_prefix)" bash "${DS_SCRIPT_DIR}/deepstream-verify.sh"
}

# The package stage: runtime packages, the TensorRT 10 loader path and the plugin directory; the lib dir stays off ld.so.conf.
ds_stage_runtime() {
  ds_load_pins
  local root gst_dir
  root="$(ds_root)"
  [ -d "${root}/lib/gst-plugins" ] || ds_die "ENABLE_DEEPSTREAM=true but ${root} was not copied into this image"
  ds_apt_install "${DS_RUNTIME_PACKAGES[@]}"
  ds_write_trt_ldconf
  gst_dir="${GSTREAMER_PREFIX:-/opt/gstreamer}/lib/$(dpkg-architecture -qDEB_HOST_MULTIARCH)/gstreamer-1.0"
  [ -d "${gst_dir}" ] || ds_die "no GStreamer plugin directory at ${gst_dir}"
  ln -sfn "${root}/lib/gst-plugins" "${gst_dir}/deepstream"
  DSV_WIRED=1 DS_ROOT="${root}" DS_TRT_PREFIX="$(ds_trt_prefix)" bash "${DS_SCRIPT_DIR}/deepstream-verify.sh"
}

# libnvinfer.so.10 has no RUNPATH and dlopen()s its builder resources, so its dir must be on the loader path; the .10 sonames collide with nothing.
ds_write_trt_ldconf() {
  printf '%s/lib\n' "$(ds_trt_prefix)" > /etc/ld.so.conf.d/010-deepstream-tensorrt.conf
  ldconfig
}

ds_assert_absent() {
  [ ! -e "${DS_OPT}" ] || ds_die "${DS_OPT} is in an image built with ENABLE_DEEPSTREAM=false (:latest and :latest-rocm must never carry it)"
  ds_log "absent, as ENABLE_DEEPSTREAM=false requires"
}

main() {
  case "${1:-}" in
    build) ds_build ;;
    stage-runtime) ds_stage_runtime ;;
    assert-absent) ds_assert_absent ;;
    *) ds_die "usage: deepstream.sh build|stage-runtime|assert-absent" ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
