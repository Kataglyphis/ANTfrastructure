#!/usr/bin/env bash
# deepstream.sh's pins, refusals and component list, and deepstream-verify.sh's verdicts; no download, no GPU.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
DS="${TESTS_DIR}/../05-frameworks/deepstream.sh"
DSV="${TESTS_DIR}/../05-frameworks/deepstream-verify.sh"
PAY="${TESTS_DIR}/../06-packaging/copy-media-payloads.sh"
ENVF="${TESTS_DIR}/../01-core/versions.env"
_T="$(mktemp -d)"
trap 'rm -rf "${_T}"' EXIT

# _ds <snippet> [VAR=value...]: deepstream.sh sourced (main does not run), the real pins loaded, then the snippet.
_ds() {
  local snippet="$1"; shift
  env "$@" bash -c 'source "$1"; source "$2"; load_versions_env "$3"; eval "$4"' _ \
    "${DS}" "${TESTS_DIR}/../01-core/load-versions-env.sh" "${ENVF}" "${snippet}" 2>&1
}

t_case "the committed pins are all usable"
t_assert_eq "" "$(_ds ds_pin_problems)" "versions.env's DEEPSTREAM_* pins pass their own shape check"

t_case "a malformed or missing pin is refused, each by name"
t_assert_contains "$(_ds ds_pin_problems DEEPSTREAM_BINARIES_AMD64_SHA256=abc)" "DEEPSTREAM_BINARIES_AMD64_SHA256='abc' is not a 64-hex sha256"
t_assert_contains "$(_ds ds_pin_problems DEEPSTREAM_TRT_LIBNVINFER10_SHA256=" ")" "DEEPSTREAM_TRT_LIBNVINFER10_SHA256"
t_assert_contains "$(_ds ds_pin_problems DEEPSTREAM_COMMIT=v9.1.0)" "DEEPSTREAM_COMMIT='v9.1.0' is not a 40-hex commit"
t_assert_contains "$(_ds ds_pin_problems DEEPSTREAM_TENSORRT_VERSION=11.3.0.99)" "is not a TensorRT 10 version" \
  "DeepStream 9.1 links libnvinfer.so.10; the variant's TensorRT 11 pin must not leak in"
t_assert_contains "$(_ds ds_pin_problems DEEPSTREAM_VERSION=latest)" "DEEPSTREAM_VERSION='latest' is not X.Y.Z"
t_assert_fails env DEEPSTREAM_COMMIT=bad bash -c 'source "$1"; ds_load_pins' _ "${DS}"

t_case "the paths and URLs follow the pins"
t_assert_eq "/opt/nvidia/deepstream/deepstream-9.1 /opt/nvidia/deepstream/tensorrt-10.16.1.11" "$(_ds 'echo "$(ds_root) $(ds_trt_prefix)"')"
t_assert_eq "https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/libnvinfer10_10.16.1.11-1+cuda13.2_amd64.deb" \
  "$(_ds 'ds_trt_deb_url libnvinfer10')"
t_assert_eq "6" "$(_ds 'ds_trt_debs | awk "NF==2 && length(\$2)==64" | wc -l')" "six debs, each with a sha256"

t_case "only amd64 and only the nvidia variant"
t_assert_eq "" "$(_ds 'ds_arch_problem amd64')"
t_assert_contains "$(_ds 'ds_arch_problem arm64')" "CON42 phase 7"
t_assert_contains "$(_ds 'ds_arch_problem riscv64')" "no runtime for 'riscv64'"
t_assert_contains "$(_ds ds_gate_problem ENABLE_NVIDIA=false)" "needs ENABLE_NVIDIA=true"
mkdir -p "${_T}/cuda/bin"; printf '#!/bin/sh\necho "Cuda compilation tools, release 13.4, V13.4.92"\n' > "${_T}/cuda/bin/nvcc"; chmod +x "${_T}/cuda/bin/nvcc"
t_assert_eq "" "$(_ds ds_gate_problem ENABLE_NVIDIA=true CUDA_HOME="${_T}/cuda")"
t_assert_contains "$(_ds ds_gate_problem ENABLE_NVIDIA=true CUDA_HOME="${_T}/nocuda")" "no nvcc"
t_assert_eq "13.4" "$(_ds ds_cuda_ver CUDA_HOME="${_T}/cuda")"

t_case "the component list: build.sh's order, minus the documented exclusions"
_S="${_T}/src"
for d in src/gst-utils/gstnvcustomhelper src/gst-utils/gst-nvdssr src/gst-utils/gstnvdscustomhelper src/utils/nvds_rest_server \
         src/utils/nvdsinfer src/utils/nvdsinferserver src/utils/nvds_msgapi/mqtt_protocol_adaptor \
         src/utils/nvds_msgapi/azure_protocol_adaptor/device_client src/utils/ds3d/dataloader/lidarsource \
         src/gst-plugins/gst-nvinfer src/gst-plugins/gst-nvinferserver src/gst-plugins/gst-nvdsudp \
         src/gst-plugins/gst-nvdspostprocess/postprocesslib_impl; do
  mkdir -p "${_S}/${d}"; : > "${_S}/${d}/Makefile"
done
mkdir -p "${_S}/src/utils/nvds_msgapi/azure_protocol_adaptor"
_LIST="$(_ds "ds_components ${_S}")"
t_assert_eq "src/gst-utils/gstnvcustomhelper" "$(printf '%s\n' "${_LIST}" | head -1)" "gst-utils first"
t_assert_eq "src/gst-plugins/gst-nvdspostprocess/postprocesslib_impl" "$(printf '%s\n' "${_LIST}" | tail -1)" "helper libraries last"
t_assert_eq "1" "$(printf '%s\n' "${_LIST}" | grep -cx src/utils/nvds_rest_server)" "nvds_rest_server once, with gst-utils"
for d in src/utils/nvdsinfer src/utils/nvds_msgapi/mqtt_protocol_adaptor src/utils/ds3d/dataloader/lidarsource src/gst-plugins/gst-nvinfer; do
  t_assert_contains "${_LIST}" "${d}" "${d} is built"
done
for d in src/utils/nvdsinferserver src/gst-plugins/gst-nvinferserver src/gst-plugins/gst-nvdsudp \
         src/utils/nvds_msgapi/azure_protocol_adaptor/device_client; do
  t_assert_eq "0" "$(printf '%s\n' "${_LIST}" | grep -cx "${d}")" "${d} is excluded"
  t_assert_ok bash -c 'source "$1"; ds_excluded_reason "$2" >/dev/null' _ "${DS}" "${d}"
done
t_assert_eq "0" "$(printf '%s\n' "${_LIST}" | grep -cx src/utils/nvds_msgapi/azure_protocol_adaptor)" "a dir without a Makefile is not a component"

t_case "each component keeps its Makefile's compilers; only C++ gets the C++-only flag"
_mf() { printf '%s\n' "$1" > "${_T}/Makefile"; bash -c 'source "$1"; ds_component_compiler "$2" "$3" /c.h' _ "${DS}" "${_T}/Makefile" "$2"; }
t_assert_eq "gcc -include /c.h" "$(_mf 'CXX:= gcc' CXX)" "gstnvcustomhelper compiles C with CXX:=gcc; g++ rejects its enum conversions"
t_assert_eq "g++ -std=c++14 -include /c.h -Wno-error=non-c-typedef-for-linkage" "$(_mf 'CXX=g++ -std=c++14 # comment' CXX)"
t_assert_eq "g++ -include /c.h -Wno-error=non-c-typedef-for-linkage" "$(_mf 'SRCS:= a.cpp' CXX)" "no CXX line means make's g++"
t_assert_eq "cc -include /c.h" "$(_mf 'SRCS:= a.cpp' CC)" "nvds_analytics compiles its C++ with make's default CC; it still needs the includes"
t_assert_eq "g++ -include /c.h" "$(_mf 'CC:= g++' CC)" "a Makefile that links with CC:=g++ keeps g++, or libstdc++ goes missing"

t_case "only GStreamer plugins may stay in gst-plugins/"
if command -v cc >/dev/null 2>&1 && command -v nm >/dev/null 2>&1; then
  mkdir -p "${_T}/gp"
  printf 'const void *gst_plugin_demo_get_desc(void) { return 0; }\n' > "${_T}/p.c"
  printf 'int helper(void) { return 1; }\n' > "${_T}/h.c"
  cc -shared -fPIC -o "${_T}/gp/libplugin.so" "${_T}/p.c" && cc -shared -fPIC -o "${_T}/gp/libhelper.so" "${_T}/h.c"
  t_assert_eq "${_T}/gp/libhelper.so" "$(bash -c 'source "$1"; dsv_non_plugins "$2"' _ "${DSV}" "${_T}/gp")" \
    "a helper .so is found; the registry scan would dlclose() it and crash the next plugin"
  # nm sorts by name, so thousands of symbols after the descriptor outlive a grep -q, which SIGPIPEs nm under pipefail.
  { printf 'const void *gst_plugin_big_get_desc(void) { return 0; }\n'; for i in $(seq 1 6000); do printf 'int zz_padding_after_the_descriptor_%05d(void) { return %d; }\n' "$i" "$i"; done; } > "${_T}/big.c"
  mkdir -p "${_T}/gp2"; cc -shared -fPIC -o "${_T}/gp2/libbig.so" "${_T}/big.c"
  t_assert_eq "" "$(bash -c 'set -o pipefail; source "$1"; dsv_non_plugins "$2"' _ "${DSV}" "${_T}/gp2")" \
    "libgstnvvideo4linux2.so was moved out of gst-plugins/ this way on 2026-10-01"
else
  t_assert_eq "cc and nm" "missing" "this case needs a C compiler and nm"
fi

t_case "apt may not bring in a distro GStreamer"
_apt() { bash -c 'source "$1"; apt-get() { case " $* " in *" -s "*) printf "Inst %s (1 x)\n" $PULL;; esac; return 0; }; ds_apt_install libfoo-dev' _ "${DS}" 2>&1; }
t_assert_contains "$(PULL="libfoo-dev libgstreamer1.0-0" _apt)" "would install a distro GStreamer: libgstreamer1.0-0"
t_assert_eq "" "$(PULL="libfoo-dev libyaml-cpp0.8" _apt)" "a GStreamer-free plan installs"

t_case "ENABLE_DEEPSTREAM=false images must not carry the tree"
mkdir -p "${_T}/opt-present"
t_assert_fails bash -c 'source "$1"; DS_OPT="$2" ds_assert_absent' _ "${DS}" "${_T}/opt-present"
t_assert_ok bash -c 'source "$1"; DS_OPT="$2" ds_assert_absent' _ "${DS}" "${_T}/opt-absent"

t_case "the package copies the tree only when asked, and fails when asked for a tree the artifact lacks"
_FNS='warn() { printf "[WARN] %s\n" "$*" >&2; }'$'\n'
for _fn in _dest copy_path copy_deepstream_payload; do _FNS+="$(t_fn_src "${PAY}" "${_fn}")"$'\n' || exit 1; done
_copy() { ENABLE_DEEPSTREAM="$1" SRCPREFIX="$2" COPY_TARGET_DIR="$3" bash -c "set -euo pipefail"$'\n'"${_FNS}"$'\ncopy_deepstream_payload' >/dev/null 2>&1; echo $?; }
mkdir -p "${_T}/art/opt/nvidia/deepstream/deepstream-9.1/lib" "${_T}/empty" "${_T}/d1" "${_T}/d2" "${_T}/d3"
echo so > "${_T}/art/opt/nvidia/deepstream/deepstream-9.1/lib/libnvds_meta.so"
t_assert_eq "0" "$(_copy true "${_T}/art" "${_T}/d1")"
t_assert_eq "so" "$(cat "${_T}/d1/opt/nvidia/deepstream/deepstream-9.1/lib/libnvds_meta.so" 2>/dev/null)" "the tree is copied"
t_assert_eq "1" "$(_copy true "${_T}/empty" "${_T}/d2")" "asked for, but the artifact has none"
t_assert_eq "0" "$(_copy false "${_T}/art" "${_T}/d3")"
t_assert_eq "absent" "$([ -e "${_T}/d3/opt/nvidia" ] && echo present || echo absent)" "a DeepStream artifact does not leak into an image that did not ask"
t_assert_contains "$(t_fn_src "${PAY}" copy_media_payloads)" "copy_deepstream_payload" "the copy is wired into the payload run"

t_case "closure verdict: driver sonames pass, an unexcused miss is BROKEN, an unused excuse is STALE"
_verdict() { printf '%b' "$1" | bash -c 'source "$1"; dsv_closure_verdict' _ "${DSV}"; }
_ALL_EXCUSED="$(bash -c 'source "$1"; for e in "${DSV_ALLOWED_MISSING[@]}"; do IFS="|" read -r f n _ <<< "$e"; echo "$f $n"; done' _ "${DSV}")"
t_assert_eq "" "$(_verdict "${_ALL_EXCUSED}\nlib/gst-plugins/libnvdsgst_infer.so libcuda.so.1\nlib/libnvds_stats.so libnvidia-ml.so.1\n")"
t_assert_contains "$(_verdict "${_ALL_EXCUSED}\nlib/gst-plugins/libnvdsgst_infer.so libnvinfer.so.10\n")" \
  "BROKEN lib/gst-plugins/libnvdsgst_infer.so -> libnvinfer.so.10"
t_assert_contains "$(_verdict "$(printf '%s\n' "${_ALL_EXCUSED}" | tail -n +2)\n")" "STALE lib/gst-plugins/libnvdsgst_ucx.so -> libucs.so.0"

t_case "one GStreamer: a plugin resolving a GStreamer soname outside the prefix is flagged"
_gst() { printf '%b' "$1" | GSTREAMER_PREFIX=/opt/gstreamer bash -c 'source "$1"; dsv_gst_origin_verdict' _ "${DSV}"; }
t_assert_eq "" "$(_gst 'libnvdsgst_infer.so libgstreamer-1.0.so.0 /opt/gstreamer/lib/x86_64-linux-gnu/libgstreamer-1.0.so.0\nlibnvdsgst_infer.so libglib-2.0.so.0 /usr/lib/x86_64-linux-gnu/libglib-2.0.so.0\n')" \
  "GLib is the distro's by design; GStreamer from the prefix"
t_assert_contains "$(_gst 'libgstnvvideoconvert.so libgstvideo-1.0.so.0 /usr/lib/x86_64-linux-gnu/libgstvideo-1.0.so.0\n')" "SECOND-GSTREAMER libgstnvvideoconvert.so"

t_case "an engine build finds TensorRT 10's builder resources, which it dlopen()s by file name"
_TRT="${_T}/opt/tensorrt-10.16.1.11/lib"; _SYS="${_T}/syslib"
mkdir -p "${_TRT}" "${_SYS}"
for r in sm75 sm86 ptx; do : > "${_TRT}/libnvinfer_builder_resource_${r}.so.10.16.1"; done
ln -s libnvinfer_builder_resource_sm75.so.10.16.1 "${_TRT}/do_not_link_against_nvinfer_builder_resource_sm75"
_link() { _ds 'ds_link_trt_builder_resources' DS_OPT="${_T}/opt" DS_SYSLIB_DIR="$1"; }
t_assert_contains "$(_link "${_SYS}")" "linked 3 TensorRT 10.16.1.11 builder resources"
t_assert_eq "${_TRT}/libnvinfer_builder_resource_sm75.so.10.16.1" "$(readlink "${_SYS}/libnvinfer_builder_resource_sm75.so.10.16.1")" \
  "the 2080's sm_75 resource: without it nvinfer stopped with 'Unable to load library' (2026-10-01)"
t_assert_eq "absent" "$([ -e "${_SYS}/do_not_link_against_nvinfer_builder_resource_sm75" ] && echo present || echo absent)" \
  "only the names TensorRT dlopen()s, not the SONAME links ldconfig made"
_vtrt() { DS_ROOT="${_T}/none" DS_TRT_PREFIX="${_T}/opt/tensorrt-10.16.1.11" DS_SYSLIB_DIR="$1" bash -c 'source "$1"; dsv_check_trt_builder_resources; echo "fail=${dsv_fail}"' _ "${DSV}"; }
t_assert_contains "$(_vtrt "${_SYS}")" "fail=0"
t_assert_contains "$(_vtrt "${_T}/syslib-empty")" "builder resources an engine build cannot dlopen"
t_assert_contains "$(_vtrt "${_T}/syslib-empty")" "fail=1"
mkdir -p "${_T}/opt-empty/tensorrt-10.16.1.11/lib"
t_assert_fails env DS_OPT="${_T}/opt-empty" DS_SYSLIB_DIR="${_SYS}" bash -c 'source "$1"; source "$2"; load_versions_env "$3"; ds_link_trt_builder_resources' _ \
  "${DS}" "${TESTS_DIR}/../01-core/load-versions-env.sh" "${ENVF}"

t_case "nvv4l2decoder reaches NVDEC only through NVIDIA's plugin in the distro libv4l2's dir"
_DSR="${_T}/opt/deepstream-9.1"; mkdir -p "${_DSR}/lib/libv4l/plugins"; : > "${_DSR}/lib/libv4l/plugins/libcuvidv4l2_plugin.so"
_V4L="${_T}/v4l-plugins"
_ds 'ds_link_v4l2_plugin' DS_OPT="${_T}/opt" DS_V4L2_PLUGIN_DIR="${_V4L}" >/dev/null
t_assert_eq "${_DSR}/lib/libv4l/plugins/libcuvidv4l2_plugin.so" "$(readlink "${_V4L}/libcuvidv4l2_plugin.so")" \
  "without it the decoder opened /dev/nvidia0 as a plain V4L2 node: 'It isn't a v4l2 driver' (2026-10-01)"
t_assert_fails env DS_OPT="${_T}/opt-empty" DS_V4L2_PLUGIN_DIR="${_V4L}" bash -c 'source "$1"; source "$2"; load_versions_env "$3"; ds_link_v4l2_plugin' _ \
  "${DS}" "${TESTS_DIR}/../01-core/load-versions-env.sh" "${ENVF}"
_vv4l() { DS_ROOT="${_DSR}" DS_TRT_PREFIX="" DS_V4L2_PLUGIN_DIR="$1" bash -c 'source "$1"; dsv_check_v4l2_plugin; echo "fail=${dsv_fail}"' _ "${DSV}"; }
t_assert_contains "$(DSV_WIRED=1 _vv4l "${_V4L}")" "fail=0"
t_assert_contains "$(DSV_WIRED=1 _vv4l "${_T}/v4l-empty")" "nvv4l2decoder cannot reach NVDEC"
t_assert_eq "fail=0" "$(DSV_WIRED=0 _vv4l "${_T}/v4l-empty")" "the build stage wires no plugin dir, so only the package checks it"

t_case "the image selects the new nvstreammux; the legacy one fails on GStreamer >= 1.28"
PKGF="${TESTS_DIR}/../../Dockerfile.package"
t_assert_contains "$(cat "${PKGF}")" 'ARG DS_NEW_MUX=${ENABLE_DEEPSTREAM/false/}'
t_assert_contains "$(cat "${PKGF}")" 'ENV USE_NEW_NVSTREAMMUX=${DS_NEW_MUX/true/yes}' \
  "NVIDIA's prebuilt legacy mux reads GstMapInfo.data after gst_buffer_unmap(), which 1.28 clears"

t_case "the gates are wired into both images"
MEDIA="${TESTS_DIR}/../../Dockerfile.media"; PKG="${TESTS_DIR}/../../Dockerfile.package"
t_assert_contains "$(cat "${MEDIA}")" 'deepstream.sh build' "the media stage builds it"
t_assert_contains "$(cat "${MEDIA}")" 'if [ "${ENABLE_DEEPSTREAM}" = "true" ]; then' "gated on ENABLE_DEEPSTREAM"
t_assert_contains "$(cat "${MEDIA}")" 'ARG ENABLE_DEEPSTREAM=false' "off by default"
t_assert_contains "$(cat "${PKG}")" 'deepstream.sh stage-runtime' "the package wires and re-verifies it"
t_assert_contains "$(cat "${PKG}")" 'deepstream.sh assert-absent' "and proves its absence otherwise"
t_assert_contains "$(t_fn_src "${DS}" ds_build)" 'deepstream-verify.sh' "the build ends in the gates"
t_assert_contains "$(t_fn_src "${DS}" ds_stage_runtime)" 'DSV_WIRED=1' "the package checks the image's own plugin path"
t_assert_contains "$(t_fn_src "${DS}" ds_stage_runtime)" 'ds_link_v4l2_plugin' "the package links the NVDEC plugin"
t_assert_contains "$(t_fn_src "${DS}" ds_stage_runtime)" 'ds_link_trt_builder_resources' "the package links the builder resources"
t_assert_contains "$(t_fn_src "${DS}" ds_build)" 'ds_link_trt_builder_resources' "and so does the build, whose gate checks them"
t_assert_contains "$(t_fn_src "${DSV}" dsv_main)" 'dsv_check_v4l2_plugin' "the plugin link is a gate"
t_assert_contains "$(t_fn_src "${DSV}" dsv_main)" 'dsv_check_trt_builder_resources' "the builder-resource links are a gate"

t_summary
