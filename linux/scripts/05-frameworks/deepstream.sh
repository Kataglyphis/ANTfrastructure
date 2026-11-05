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
  # civetweb's USE_ZLIB: on a cross build the target's zconf.h lives in its multiarch dir, never pulled in by chance.
  zlib1g-dev
)

# shellcheck source=deepstream-verify.sh
source "${DS_SCRIPT_DIR}/deepstream-verify.sh"

ds_log() { printf '[deepstream] %s\n' "$*"; }
ds_die() { printf '[deepstream] ERROR: %s\n' "$*" >&2; exit 1; }

ds_core_dir() {
  local d
  : "${DS_CORE_DIR:=}"
  for d in "${DS_CORE_DIR}" "${DS_SCRIPT_DIR}/../01-core" /opt/scripts/core; do
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
  for v in DEEPSTREAM_BINARIES_AMD64_SHA256 DEEPSTREAM_BINARIES_ARM64_SHA256 $(ds_trt_pin_keys "") $(ds_trt_pin_keys _ARM64) \
           DEEPSTREAM_SBSA_LIBNVBUFSURFACE_SHA256 DEEPSTREAM_SBSA_LIBNVBUFSURFTRANSFORM_SHA256 DEEPSTREAM_SBSA_LIBNVDSBUFFERPOOL_SHA256; do
    [[ "${!v:-}" =~ ^[0-9a-f]{64}$ ]] || echo "${v}='${!v:-}' is not a 64-hex sha256"
  done
  [[ "${DEEPSTREAM_SBSA_IMAGE:-}" =~ ^[^@[:space:]]+@sha256:[0-9a-f]{64}$ ]] \
    || echo "DEEPSTREAM_SBSA_IMAGE='${DEEPSTREAM_SBSA_IMAGE:-}' is not an image reference pinned by digest"
  return 0
}

# <suffix>: the six TensorRT 10 deb pin keys, "" for amd64 and _ARM64 for the sbsa debs.
ds_trt_pin_keys() {
  local k
  for k in LIBNVINFER10 LIBNVINFER_PLUGIN10 LIBNVONNXPARSERS10 LIBNVINFER_HEADERS_DEV LIBNVINFER_HEADERS_PLUGIN_DEV LIBNVONNXPARSERS_DEV; do
    printf 'DEEPSTREAM_TRT_%s%s_SHA256\n' "${k}" "$1"
  done
}

ds_load_pins() {
  local core problems
  core="$(ds_core_dir)" || ds_die "no 01-core dir with versions.env and downloads.sh (set DS_CORE_DIR)"
  # common.sh loads versions.env and downloads.sh, and owns the compiler-cache resolver.
  # shellcheck disable=SC1091
  source "${core}/common.sh"
  # The cross modules: compilers, target apt and the CUDA cross target for a media build whose image is another arch's.
  # shellcheck disable=SC1091
  source "${core}/modules.sh"
  source_modules_framework "${DS_SCRIPT_DIR}"
  source_module cross-env.sh
  source_module cross-apt.sh
  source_module cross-meson.sh
  source_module cross-cuda.sh
  problems="$(ds_pin_problems)"
  [ -z "${problems}" ] || ds_die "refusing to build with unusable pins:"$'\n'"${problems}"
}

# Refuses a distro GStreamer: /opt/gstreamer must stay the only copy. Under a cross build the target's packages, through cross-apt.
ds_apt_install() {
  local pulled p
  local -a pkgs=()
  if ds_cross_active; then
    cross_prepare_foreign_arch
    for p in "$@"; do pkgs+=("${p}:$(ds_arch)"); done
  else
    pkgs=("$@")
  fi
  apt-get update -qq
  pulled="$(apt-get install -s -y --no-install-recommends "${pkgs[@]}" | awk '/^Inst /{print $2}' | grep -E 'gstreamer|^libgst' || true)"
  [ -z "${pulled}" ] || ds_die "these packages would install a distro GStreamer: ${pulled//$'\n'/ }"
  if ds_cross_active; then
    install_target_packages "$@"
  else
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
  fi
}

ds_root() { printf '%s/deepstream-%s' "${DS_OPT}" "${DEEPSTREAM_VERSION%.*}"; }
ds_trt_prefix() { printf '%s/tensorrt-%s' "${DS_OPT}" "${DEEPSTREAM_TENSORRT_VERSION}"; }

# In a cross media build dpkg says amd64 while the image is the target's: TARGET_ARCH decides.
ds_arch() { printf '%s' "${TARGET_ARCH:-$(dpkg --print-architecture)}"; }
ds_cross_active() {
  if [ "$(ds_arch)" != "$(dpkg --print-architecture)" ]; then return 0; fi
  return 1
}
ds_multiarch() { case "$(ds_arch)" in amd64) printf 'x86_64-linux-gnu' ;; arm64) printf 'aarch64-linux-gnu' ;; *) return 1 ;; esac; }
# The Makefiles read `gcc -dumpmachine`, which names the build host under a cross build.
ds_target_device() { case "$(ds_arch)" in amd64) printf 'x86_64' ;; arm64) printf 'aarch64' ;; *) return 1 ;; esac; }
ds_runtime_asset() {
  case "$(ds_arch)" in
    amd64) printf 'deepstream-binaries-x86_%s_amd64.deb' "${DEEPSTREAM_VERSION}" ;;
    arm64) printf 'deepstream-binaries-aarch64_%s_arm64.deb' "${DEEPSTREAM_VERSION}" ;;
    *) return 1 ;;
  esac
}
ds_runtime_asset_sha() { case "$(ds_arch)" in amd64) printf '%s' "${DEEPSTREAM_BINARIES_AMD64_SHA256}" ;; arm64) printf '%s' "${DEEPSTREAM_BINARIES_ARM64_SHA256}" ;; *) return 1 ;; esac; }

# The Jetson .deb leaves these to L4T; the arm64 route stages NVIDIA's SBSA copies by hand (docs/linux-accelerator-images.md#deepstream-on-arm64-sbsa).
ds_sbsa_dir() { printf '%s' "${DS_SBSA_DIR:-/opt/deepstream-sbsa}"; }
ds_sbsa_libs() {
  printf '%s %s\n' \
    libnvbufsurface.so.1.0.0 DEEPSTREAM_SBSA_LIBNVBUFSURFACE_SHA256 \
    libnvbufsurftransform.so.1.0.0 DEEPSTREAM_SBSA_LIBNVBUFSURFTRANSFORM_SHA256 \
    libnvdsbufferpool.so DEEPSTREAM_SBSA_LIBNVDSBUFFERPOOL_SHA256
}

# Prints every staged SBSA library that is missing or not the pinned bytes; empty output means the route can build.
ds_sbsa_problem() {
  local dir f key have
  dir="$(ds_sbsa_dir)"
  while read -r f key; do
    if [ ! -f "${dir}/${f}" ]; then
      echo "${dir}/${f} is not staged: run linux/scripts/05-frameworks/stage-deepstream-sbsa.sh on the build host (DEEPSTREAM_SBSA_IMAGE)"
      continue
    fi
    have="$(sha256sum "${dir}/${f}" | cut -d' ' -f1)"
    [ "${have}" = "${!key:-}" ] || echo "${dir}/${f} is not the pinned ${key} (sha256 ${have})"
  done < <(ds_sbsa_libs)
}

# amd64 from NVIDIA's release; arm64 from the Jetson release plus the staged SBSA libraries (CON42 phase 7); nothing else.
ds_arch_problem() {
  local arch="${1:-}"
  case "${arch}" in
    amd64) return 0 ;;
    arm64) ds_sbsa_problem ;;
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

# ds_fetch <url> <sha256> <dest>: a verified download, reusing a verified copy from DS_DOWNLOAD_CACHE.
ds_fetch() {
  : "${DS_DOWNLOAD_CACHE:=}"
  download_verified_cached "$1" "$2" "$3" "${DS_DOWNLOAD_CACHE}"
}

ds_stage_runtime_deb() {
  local tmp="$1" deb asset
  asset="$(ds_runtime_asset)" || ds_die "no runtime asset for $(ds_arch)"
  deb="${tmp}/${asset}"
  ds_fetch "${DS_RELEASE_URL}/v${DEEPSTREAM_VERSION}/${asset}" "$(ds_runtime_asset_sha)" "${deb}"
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
  [ "$(ds_arch)" != arm64 ] || ds_stage_sbsa_libs
}

# The three Tegra libraries, verified against their pins, into the tree with the unversioned links the plugins and the Makefiles link.
ds_stage_sbsa_libs() {
  local problem dir lib f key
  problem="$(ds_sbsa_problem)"; [ -z "${problem}" ] || ds_die "${problem}"
  dir="$(ds_sbsa_dir)"; lib="$(ds_root)/lib"
  while read -r f key; do
    cp "${dir}/${f}" "${lib}/${f}"
    case "${f}" in *.so.1.0.0) ln -sfn "${f}" "${lib}/${f%.1.0.0}" ;; esac
  done < <(ds_sbsa_libs)
  ds_log "SBSA libraries from ${DEEPSTREAM_SBSA_IMAGE} -> ${lib}"
}

# <KEY>: the sha256 pin of one TensorRT 10 deb for this arch (DEEPSTREAM_TRT_<KEY>[_ARM64]_SHA256).
ds_trt_pin() {
  local key="DEEPSTREAM_TRT_$1_SHA256"
  [ "$(ds_arch)" != arm64 ] || key="DEEPSTREAM_TRT_$1_ARM64_SHA256"
  printf '%s' "${!key:-}"
}

# "<package> <sha256>" per TensorRT 10 runtime deb: the libraries the prefix ships.
ds_trt_runtime_debs() {
  printf '%s %s\n' \
    libnvinfer10 "$(ds_trt_pin LIBNVINFER10)" \
    libnvinfer-plugin10 "$(ds_trt_pin LIBNVINFER_PLUGIN10)" \
    libnvonnxparsers10 "$(ds_trt_pin LIBNVONNXPARSERS10)"
}

# The headers the sources compile against; the SLA lets only the runtime .so files ship, so these stay in the build's tmp.
ds_trt_dev_debs() {
  printf '%s %s\n' \
    libnvinfer-headers-dev "$(ds_trt_pin LIBNVINFER_HEADERS_DEV)" \
    libnvinfer-headers-plugin-dev "$(ds_trt_pin LIBNVINFER_HEADERS_PLUGIN_DEV)" \
    libnvonnxparsers-dev "$(ds_trt_pin LIBNVONNXPARSERS_DEV)"
}

ds_trt_debs() { ds_trt_runtime_debs; ds_trt_dev_debs; }

# NVIDIA's repo keys the path by x86_64 or sbsa and the file by the Debian arch.
ds_trt_deb_url() {
  local path
  case "$(ds_arch)" in amd64) path=x86_64 ;; arm64) path=sbsa ;; *) return 1 ;; esac
  printf '%s/%s/%s/%s_%s-1+cuda%s_%s.deb' "${DS_TRT_REPO_URL}" "${DEEPSTREAM_TENSORRT_REPO}" "${path}" \
    "$1" "${DEEPSTREAM_TENSORRT_VERSION}" "${DEEPSTREAM_TENSORRT_CUDA}" "$(ds_arch)"
}

# The headers and dev links the components build against, under ds_build's tmp so no layer keeps them.
ds_trt_sdk() { printf '%s/trt-sdk' "$1"; }

# ds_trt_extract <dir> <list function>: each deb the function names, verified, unpacked into <dir>.
ds_trt_extract() {
  local dir="$1" pkg sha deb
  mkdir -p "${dir}"
  while read -r pkg sha; do
    deb="${dir}.${pkg}.deb"
    ds_fetch "$(ds_trt_deb_url "${pkg}")" "${sha}" "${deb}"
    dpkg-deb -x "${deb}" "${dir}"
    rm -f "${deb}"
  done < <("$2")
}

# The prefix gets the runtime .so files and their docs; headers and dev links go to ds_trt_sdk only.
ds_stage_tensorrt() {
  local tmp="$1" prefix sdk lib
  prefix="$(ds_trt_prefix)"
  sdk="$(ds_trt_sdk "${tmp}")"
  ds_trt_extract "${tmp}/trt-rt" ds_trt_runtime_debs
  ds_trt_extract "${tmp}/trt-dev" ds_trt_dev_debs
  rm -rf "${prefix}" "${sdk}"
  mkdir -p "${prefix}/lib" "${prefix}/doc" "${sdk}/include" "${sdk}/lib"
  find "${tmp}/trt-rt/usr/lib/$(ds_multiarch)" -maxdepth 1 -name '*.so.*' -exec cp -a {} "${prefix}/lib/" \;
  cp -a "${tmp}/trt-rt/usr/share/doc/." "${prefix}/doc/"
  cp -a "${tmp}/trt-dev/usr/include/$(ds_multiarch)/." "${sdk}/include/"
  for lib in libnvinfer libnvinfer_plugin libnvonnxparser; do
    [ -e "${prefix}/lib/${lib}.so.10" ] || ds_die "TensorRT ${DEEPSTREAM_TENSORRT_VERSION}: no ${lib}.so.10 in the debs"
    ln -sfn "${prefix}/lib/${lib}.so.10" "${sdk}/lib/${lib}.so"
  done
  rm -rf "${tmp}/trt-rt" "${tmp}/trt-dev"
  ds_log "TensorRT ${DEEPSTREAM_TENSORRT_VERSION}: runtime -> ${prefix}, headers and dev links -> ${sdk} (build only)"
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
  local base var="$2" cxx_only=""
  base="$(sed -nE "s/^${var}[[:space:]]*[:?]?=[[:space:]]*([^#]*[^#[:space:]]).*/\\1/p" "$1" | head -1)"
  if [ -z "${base}" ]; then
    if [ "${var}" = CXX ]; then base=g++; else base=cc; fi
  fi
  case "${var}:${base%% *}" in
    CXX:gcc|CXX:cc|CC:*) ;;
    *) cxx_only=" -Wno-error=non-c-typedef-for-linkage" ;;
  esac
  # A cross build keeps each Makefile's compiler KIND and swaps in the target toolchain's binary (DS_CROSS_CC/DS_CROSS_CXX).
  if [ -n "${DS_CROSS_CC:-}" ] && [ -n "${DS_CROSS_CXX:-}" ]; then
    case "${base%% *}" in
      g++|c++) base="${DS_CROSS_CXX}${base#"${base%% *}"}" ;;
      gcc|cc) base="${DS_CROSS_CC}${base#"${base%% *}"}" ;;
    esac
  fi
  printf '%s%s -include %s%s' "${DS_CACHE_LAUNCHER:+${DS_CACHE_LAUNCHER} }" "${base}" "$3" "${cxx_only}"
}

# The libdir that carries gstreamer-1.0.pc, as configure-runtime.sh resolves it for the final image.
ds_gst_libdir() {
  local pc
  pc="$(find "${GSTREAMER_PREFIX:-/opt/gstreamer}/lib" -name gstreamer-1.0.pc -type f 2>/dev/null | head -1 || true)"
  [ -n "${pc}" ] || ds_die "no gstreamer-1.0.pc under ${GSTREAMER_PREFIX:-/opt/gstreamer}/lib"
  dirname "$(dirname "${pc}")"
}

# The media build stages export no PKG_CONFIG_PATH for /opt/gstreamer; the components' Makefiles ask pkg-config for gstreamer-1.0.
ds_gst_pkgconfig_path() {
  local libdir
  libdir="$(ds_gst_libdir)" || exit 1
  printf '%s/pkgconfig%s' "${libdir}" "${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}"
}

# The build stage has no 000-gstreamer.conf and does have the distro core packagekit pulls in, so ld.so picked 1.28 and it refused every 1.29 plugin.
ds_write_gst_ldconf() {
  local libdir
  libdir="$(ds_gst_libdir)" || exit 1
  printf '%s\n%s/lib\n' "${libdir}" "${GSTREAMER_PREFIX:-/opt/gstreamer}" > "${DS_LDCONF_DIR:-/etc/ld.so.conf.d}/000-gstreamer.conf"
  ldconfig
}

# nvstreammux is a static archive gst-nvmultistream2 links, so it is built but not installed, as in build.sh.
ds_build_component() {
  local src="$1" dir="$2" log="$3" cxx cc jobs
  cxx="$(ds_component_compiler "${src}/${dir}/Makefile" CXX "${DS_COMPAT_H}")${DS_TRT_LINK_FLAGS:+ ${DS_TRT_LINK_FLAGS}}"
  cc="$(ds_component_compiler "${src}/${dir}/Makefile" CC "${DS_COMPAT_H}")${DS_TRT_LINK_FLAGS:+ ${DS_TRT_LINK_FLAGS}}"
  jobs="${DS_JOBS:-$(nproc)}"
  local -a mk=(make -C "${src}/${dir}" -j"${jobs}" "CUDA_VER=${DS_CUDA_VER}" "CXX=${cxx}" "CC=${cc}"
               "NVDS_VERSION=${DEEPSTREAM_VERSION%.*}" PROTOBUF_BIN_DIR=/usr/bin ${DS_TARGET_DEVICE:+"TARGET_DEVICE=${DS_TARGET_DEVICE}"})
  if "${mk[@]}" >"${log}" 2>&1 && { [ "${dir}" = src/utils/nvstreammux ] || "${mk[@]}" install >>"${log}" 2>&1; }; then
    return 0
  fi
  tail -n 40 "${log}" >&2
  ds_die "component ${dir} failed to build (log above)"
}

ds_build_components() {
  local src="$1" logdir="$2" sdk="$3" dir n=0 trt
  trt="$(ds_trt_prefix)"
  mkdir -p "${logdir}" "$(ds_root)/lib/gst-plugins" "$(ds_root)/bin"
  DS_COMPAT_H="${logdir}/gcc16-compat.h"
  ds_write_compat_header "${DS_COMPAT_H}"
  DS_CUDA_VER="$(ds_cuda_ver)"
  compiler_cache_launcher_env 2>/dev/null || true
  DS_CACHE_LAUNCHER="$(compiler_cache_launcher)" || DS_CACHE_LAUNCHER=""
  [ -n "${DS_CUDA_VER}" ] || ds_die "cannot read the CUDA version from nvcc"
  if ds_cross_active; then
    DS_TARGET_DEVICE="$(ds_target_device)"
    DS_CROSS_CC="${CC}" DS_CROSS_CXX="${CXX}"
    # The Makefiles hard-code /usr/local/cuda-$(CUDA_VER)/{include,lib64}: a view names the target's, and nvcc stays the host's.
    DS_CUDA_VER="${DS_CUDA_VER}-${CUDA_CROSS_TARGET_DIR}"
    ds_write_cuda_cross_view "/usr/local/cuda-${DS_CUDA_VER}"
    export NVCC_PREPEND_FLAGS="${NVCC_PREPEND_FLAGS:-} -ccbin ${CXX} --target-directory=${CUDA_CROSS_TARGET_DIR}"
  fi
  [ -e "/usr/local/cuda-${DS_CUDA_VER}" ] || ds_die "the Makefiles expect /usr/local/cuda-${DS_CUDA_VER}"
  export CPATH="${sdk}/include${CPATH:+:${CPATH}}"
  export LIBRARY_PATH="${sdk}/lib:${trt}/lib:/usr/local/cuda-${DS_CUDA_VER}/lib64:/usr/local/cuda-${DS_CUDA_VER}/lib64/stubs${LIBRARY_PATH:+:${LIBRARY_PATH}}"
  # GCC 16 searches /usr/lib/x86_64-linux-gnu (TensorRT 11's dev links) before a bare LIBRARY_PATH dir: on 2026-10-28 -lnvinfer linked .so.11; only an explicit -L precedes it.
  DS_TRT_LINK_FLAGS="-L${sdk}/lib"
  export NVCC_PREPEND_FLAGS="${NVCC_PREPEND_FLAGS:-} -include ${logdir}/gcc16-compat.h"
  PKG_CONFIG_PATH="$(ds_gst_pkgconfig_path)"
  export PKG_CONFIG_PATH
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
  make -C "${w}/civetweb" -j"${DS_JOBS:-$(nproc)}" slib WITH_ALL=1 WITH_CPP=1 ${DS_CROSS_CC:+"CC=${DS_CROSS_CC}" "CXX=${DS_CROSS_CXX}"} \
    LDFLAGS="-Wl,--version-script,${w}/civetweb/civetweb.ver" >"${w}/civetweb.log" 2>&1 \
    || { grep -n -B2 -A2 -e 'error' "${w}/civetweb.log" | tail -n 40 >&2; tail -n 20 "${w}/civetweb.log" >&2; ds_die "civetweb failed (its error lines, then its tail, above)"; }
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
  local -a cross_args=()
  append_cmake_cross_args cross_args
  if ! { cmake -S "${srcdir}" -B "${b}/build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON \
           -DCMAKE_INSTALL_PREFIX="${b}/install" -DCMAKE_INSTALL_RPATH='$ORIGIN' -Wno-dev "${cross_args[@]}" "$@" >"${b}.log" 2>&1 \
         && cmake --build "${b}/build" >>"${b}.log" 2>&1 && cmake --install "${b}/build" >>"${b}.log" 2>&1; }; then
    tail -n 40 "${b}.log" >&2
    ds_die "${srcdir##*/} failed to build"
  fi
}

# <dir>: bin from the host toolkit, include and lib64 from the cross target (CUDA_CROSS_TARGET_ROOT), so CUDA_VER paths link the target's libraries.
ds_write_cuda_cross_view() {
  [ -n "${CUDA_CROSS_TARGET_ROOT:-}" ] || ds_die "CUDA_CROSS_TARGET_ROOT is unset; the gpu stage's cross-target.env did not load"
  rm -rf "$1"; mkdir -p "$1"
  ln -s "${CUDA_HOME:-/usr/local/cuda}/bin" "$1/bin"
  ln -s "${CUDA_CROSS_TARGET_ROOT}/include" "$1/include"
  ln -s "${CUDA_CROSS_TARGET_ROOT}/lib" "$1/lib64"
  ds_log "CUDA cross view $1 -> ${CUDA_CROSS_TARGET_ROOT}"
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
  # In a cross media build dpkg says amd64 while the image is the target's: judge TARGET_ARCH.
  problem="$(ds_arch_problem "${TARGET_ARCH:-$(dpkg --print-architecture)}")"; [ -z "${problem}" ] || ds_die "${problem}"
  problem="$(ds_gate_problem)"; [ -z "${problem}" ] || ds_die "${problem}"
  ds_cross_setup
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/deepstream.XXXXXX")"
  ds_apt_install "${DS_BUILD_PACKAGES[@]}" "${DS_RUNTIME_PACKAGES[@]}"
  ds_stage_runtime_deb "${tmp}"
  ds_stage_tensorrt "${tmp}"
  ds_fetch_sources "${tmp}/src"
  ds_build_rest_server_deps "${tmp}/deps"
  ds_build_components "${tmp}/src" "${tmp}/logs" "$(ds_trt_sdk "${tmp}")"
  ds_fix_layout "$(ds_root)"
  rm -rf "${tmp}" ${DS_TARGET_DEVICE:+"/usr/local/cuda-${DS_CUDA_VER}"}
  ds_write_gst_ldconf
  ds_write_trt_ldconf
  ds_link_trt_builder_resources
  # Foreign ELF cannot run here: the closure, loader and registration gates wait for the package stage, which runs them natively.
  DSV_CROSS="$(ds_cross_active && echo 1 || echo 0)" DSV_MULTIARCH="$(ds_multiarch)" DSV_NM="${NM:-nm}" \
    DS_ROOT="$(ds_root)" DS_TRT_PREFIX="$(ds_trt_prefix)" bash "${DS_SCRIPT_DIR}/deepstream-verify.sh"
}

# A cross media build needs the target toolchain (CC/CXX/NM) and the gpu stage's CUDA cross target; the deps and components read both.
ds_cross_setup() {
  ds_cross_active || return 0
  [ "${BUILD_MODE:-native}" = cross ] || ds_die "TARGET_ARCH=$(ds_arch) on a $(dpkg --print-architecture) build host needs BUILD_MODE=cross"
  setup_linux_cross_env || ds_die "no cross toolchain for $(ds_arch) in this image"
  cuda_cross_active || ds_die "no CUDA cross target in this image ($(cuda_cross_env_file)); the gpu stage must run with CROSS_NVIDIA_SBSA=1"
  cuda_cross_load
  # The Makefile builds take no cross file, and the cross GCC's sysroot is /usr/<triplet>: apt's :<arch> headers and libs ride the compiler string, lowest priority like cross-meson's -idirafter.
  local multiarch
  multiarch="$(ds_multiarch)"
  DS_CROSS_SYSFLAGS="-idirafter /usr/include/${multiarch} -idirafter /usr/include -L/usr/lib/${multiarch}"
  DS_CROSS_CC="${CC} ${DS_CROSS_SYSFLAGS}" DS_CROSS_CXX="${CXX} ${DS_CROSS_SYSFLAGS}"
  DSV_NM="${NM}"
  DSV_MULTIARCH="$(ds_multiarch)"
  export DSV_NM DSV_MULTIARCH
  ds_log "cross build for $(ds_arch): CC=${CC}, CUDA target ${CUDA_CROSS_TARGET_DIR}"
}

# The package stage: runtime packages, the TensorRT 10 loader path and the plugin directory; the lib dir stays off ld.so.conf.
ds_stage_runtime() {
  ds_load_pins
  local root gst_dir
  root="$(ds_root)"
  [ -d "${root}/lib/gst-plugins" ] || ds_die "ENABLE_DEEPSTREAM=true but ${root} was not copied into this image"
  ds_apt_install "${DS_RUNTIME_PACKAGES[@]}"
  ds_write_trt_ldconf
  ds_link_trt_builder_resources
  if [ "$(ds_arch)" = amd64 ]; then ds_link_v4l2_plugin; else ds_log "no NVDEC libv4l2 plugin on $(ds_arch): nvv4l2decoder is not part of the SBSA route"; fi
  # The licence makes only the runtime .so files distributable; static archives serve builds only.
  find "${root}" -name '*.a' -type f -delete
  gst_dir="${GSTREAMER_PREFIX:-/opt/gstreamer}/lib/$(dpkg-architecture -qDEB_HOST_MULTIARCH)/gstreamer-1.0"
  [ -d "${gst_dir}" ] || ds_die "no GStreamer plugin directory at ${gst_dir}"
  ln -sfn "${root}/lib/gst-plugins" "${gst_dir}/deepstream"
  DSV_WIRED=1 DSV_ARCH="$(ds_arch)" DS_ROOT="${root}" DS_TRT_PREFIX="$(ds_trt_prefix)" bash "${DS_SCRIPT_DIR}/deepstream-verify.sh"
}

# libnvinfer.so.10 has no RUNPATH, so nvinfer and the tracker find TensorRT 10 through the loader path; the .10 sonames collide with nothing.
ds_write_trt_ldconf() {
  printf '%s/lib\n' "$(ds_trt_prefix)" > /etc/ld.so.conf.d/010-deepstream-tensorrt.conf
  ldconfig
}

# An engine build dlopen()s these by file name, which ld.so.cache never holds (it keys them by their do_not_link_against_* SONAME), so they need a default-dir link.
ds_link_trt_builder_resources() {
  local f n=0 dir
  dir="$(dsv_syslib_dir)"
  while IFS= read -r f; do
    ln -sfn "${f}" "${dir}/${f##*/}"
    n=$((n + 1))
  done < <(dsv_trt_builder_resources "$(ds_trt_prefix)")
  [ "${n}" -gt 0 ] || ds_die "no TensorRT builder resources in $(ds_trt_prefix)/lib"
  ds_log "linked ${n} TensorRT ${DEEPSTREAM_TENSORRT_VERSION} builder resources into ${dir}"
}

# nvv4l2decoder reaches NVDEC through this libv4l2 plugin, and the distro libv4l2 loads plugins only from its own dir.
ds_link_v4l2_plugin() {
  local plugin dir
  plugin="$(ds_root)/lib/libv4l/plugins/libcuvidv4l2_plugin.so"
  dir="$(dsv_v4l2_plugin_dir)"
  [ -f "${plugin}" ] || ds_die "the runtime has no ${plugin}"
  mkdir -p "${dir}"
  ln -sfn "${plugin}" "${dir}/libcuvidv4l2_plugin.so"
  ds_log "libv4l2 plugin ${plugin##*/} -> ${dir}"
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
