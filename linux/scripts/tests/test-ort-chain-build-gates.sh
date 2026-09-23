#!/usr/bin/env bash
# OpenCV, FFmpeg and the gst onnx plugin build against the chain ONNX Runtime only (owner rule 2026-09-23).
# NOT covered: a real cmake/meson/configure run -- the gates read those tools' records, faked here.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
MEDIA="${TESTS_DIR}/../03-media/build"
OCV_ORT="${MEDIA}/opencv/opencv-ort.sh"
OCV="${MEDIA}/opencv/build-opencv.sh"
DNN="${MEDIA}/ffmpeg/ffmpeg-dnn-backends.sh"
GST_ORT="${MEDIA}/gstreamer/common/gst-onnx-ort.sh"
GST="${MEDIA}/gstreamer/common/build-gstreamer-monorepo.sh"
# Git Bash on a Windows host makes copies for `ln -s` without this; a no-op on Linux.
export MSYS=winsymlinks:nativestrict

_fx="$(mktemp -d)"
trap 'rm -rf "${_fx}"' EXIT
# A chain ORT the way the onnxruntime stage lays it out, and a foreign one beside it.
_chain="${_fx}/chain"
mkdir -p "${_chain}/lib" "${_chain}/include/onnxruntime/core/providers/dml" "${_chain}/include/onnxruntime/core/session"
printf 'chain-ort-1.30.0' > "${_chain}/lib/libonnxruntime.so.1.30.0"
ln -s libonnxruntime.so.1.30.0 "${_chain}/lib/libonnxruntime.so.1"
ln -s libonnxruntime.so.1.30.0 "${_chain}/lib/libonnxruntime.so"
touch "${_chain}/include/onnxruntime_c_api.h" "${_chain}/include/onnxruntime_cxx_api.h" \
      "${_chain}/include/onnxruntime/core/providers/dml/dml_provider_factory.h"
_foreign="${_fx}/foreign"
mkdir -p "${_foreign}/lib" "${_foreign}/include"
printf 'microsoft-ort-1.25.1' > "${_foreign}/lib/libonnxruntime.so"
touch "${_foreign}/include/onnxruntime_c_api.h"

# ── OpenCV ───────────────────────────────────────────────────────────────────
# shellcheck source=../03-media/build/opencv/opencv-ort.sh
source "${OCV_ORT}"
_compat="${_fx}/build/ort-compat"

t_case "opencv: a missing chain ORT is an error, never a silent WITH_ONNXRUNTIME=OFF"
t_assert_eq "1" "$(t_rc opencv_ort_compat_tree "${_fx}/nochain" "${_compat}")"
t_assert_contains "$(t_out opencv_ort_compat_tree "${_fx}/nochain" "${_compat}")" "chain ONNX Runtime missing"
t_assert_eq "0" "$(grep -c -e 'WITH_ONNXRUNTIME=OFF' "${OCV}" "${OCV_ORT}" | awk -F: '{s+=$2} END {print s}')" \
  "the old fallback built OpenCV without ORT when the chain dir was absent"

t_case "opencv: the compat tree is the chain, minus the Windows-only DML headers"
t_assert_ok opencv_ort_compat_tree "${_chain}" "${_compat}"
t_assert_ok test -f "${_compat}/include/onnxruntime_cxx_api.h"
t_assert_fails test -e "${_compat}/include/onnxruntime/core/providers/dml"
t_assert_eq "$(readlink -f "${_chain}/lib")" "$(readlink -f "${_compat}/lib")"

t_case "opencv: the version comes off the chain's real library"
t_assert_eq "1.30.0" "$(opencv_ort_version "${_chain}/lib")"
t_assert_eq "1" "$(t_rc opencv_ort_version "${_foreign}/lib")"

t_case "opencv: every ORT cache input is explicit"
_args=()
opencv_ort_cmake_args _args "${_compat}" "1.30.0"
for _want in -DWITH_ONNXRUNTIME=ON -DHAVE_ONNXRUNTIME=1 -DDOWNLOAD_ONNXRUNTIME=OFF \
    -DDOWNLOAD_ONNXRUNTIME_GPU=OFF -DONNXRUNTIME_PREFER_STATIC=OFF "-DONNXRT_ROOT_DIR=${_compat}" \
    -DONNXRUNTIME_VERSION=1.30.0 -DCMAKE_DISABLE_FIND_PACKAGE_onnxruntime=ON \
    -DCMAKE_DISABLE_FIND_PACKAGE_ONNXRuntime=ON; do
  t_assert_contains " ${_args[*]} " " ${_want} "
done

# A configure that took the chain: dnn's own messages and the cache FindONNX leaves behind.
_log="${_fx}/configure.log"
_cache="${_fx}/CMakeCache.txt"
_good_log() {
  printf '%s\n' "-- DNN: ONNX Runtime enabled" "--   ONNX Runtime:                  YES (ver 1.30.0)" \
    "--     Include path:                ${_compat}/include" > "${_log}"
}
_good_cache() {
  printf '%s\n' "ONNXRT_ROOT_DIR:PATH=${_compat}" "ONNX_VERSION:STRING=1.30.0" \
    "ONNX_INCLUDE_DIR:STRING=${_compat}/include" "ONNX_LIBRARIES:STRING=${_compat}/lib/libonnxruntime.so" \
    "onnxruntime_DIR:PATH=onnxruntime_DIR-NOTFOUND" > "${_cache}"
}
_cfg() { opencv_ort_configure_findings "${_log}" "${_cache}" "${_compat}" "${_chain}" "1.30.0"; }

t_case "opencv configure gate: the chain-only configure is clean"
_good_log; _good_cache
t_assert_eq "" "$(_cfg)"

t_case "opencv configure gate: dnn's 1.25.1 download is caught (the Windows lanes' 2026-09-22 shape)"
_good_log; _good_cache
echo "-- DNN: Downloading ONNX Runtime package from https://github.com/microsoft/onnxruntime/releases/download/v1.25.1/onnxruntime-linux-x64-1.25.1.tgz" >> "${_log}"
t_assert_contains "$(_cfg)" "configure log: -- DNN: Downloading ONNX Runtime"
_good_log
sed -i "s|^ONNXRT_ROOT_DIR:PATH=.*|ONNXRT_ROOT_DIR:PATH=${_fx}/build/3rdparty/onnxruntime/onnxruntime-linux-x64-1.25.1|" "${_cache}"
t_assert_contains "$(_cfg)" "CMakeCache: ONNXRT_ROOT_DIR:PATH=${_fx}/build/3rdparty/onnxruntime"
sed -i "s|^ONNXRT_ROOT_DIR:PATH=.*|ONNXRT_ROOT_DIR:PATH=/usr|" "${_cache}"
t_assert_contains "$(_cfg)" "CMakeCache: ONNXRT_ROOT_DIR='/usr', not ${_compat}"

t_case "opencv configure gate: dnn must report ORT enabled, at the chain's version"
_good_cache
printf '%s\n' "--   ONNX Runtime:   YES (ver 1.25.1)" > "${_log}"
t_assert_contains "$(_cfg)" "no 'DNN: ONNX Runtime enabled'"
t_assert_contains "$(_cfg)" "no 'ONNX Runtime: YES (ver 1.30.0)'"
_good_log
sed -i 's/^ONNX_VERSION:STRING=.*/ONNX_VERSION:STRING=1.25.1/' "${_cache}"
t_assert_contains "$(_cfg)" "ONNX_VERSION='1.25.1'"

t_case "opencv configure gate: the linked library must be the chain's, shared, and no CMake package"
_good_log; _good_cache
sed -i "s|^ONNX_LIBRARIES:STRING=.*|ONNX_LIBRARIES:STRING=${_foreign}/lib/libonnxruntime.so|" "${_cache}"
t_assert_contains "$(_cfg)" "not into $(readlink -f "${_chain}/lib")"
_good_cache
touch "${_chain}/lib/libonnxruntime.a"
sed -i "s|^ONNX_LIBRARIES:STRING=.*|ONNX_LIBRARIES:STRING=${_chain}/lib/libonnxruntime.a|" "${_cache}"
t_assert_contains "$(_cfg)" "is a static ORT"
rm -f "${_chain}/lib/libonnxruntime.a"
_good_cache
sed -i "s|^onnxruntime_DIR:PATH=.*|onnxruntime_DIR:PATH=/usr/lib/cmake/onnxruntime|" "${_cache}"
t_assert_contains "$(_cfg)" "onnxruntime_DIR='/usr/lib/cmake/onnxruntime'"
sed -i "s|^ONNX_INCLUDE_DIR:STRING=.*|ONNX_INCLUDE_DIR:STRING=/usr/include/onnxruntime|" "${_cache}"
t_assert_contains "$(_cfg)" "ONNX_INCLUDE_DIR='/usr/include/onnxruntime' is outside"

t_case "opencv configure gate: no log or no cache is a finding, never a pass"
t_assert_contains "$(opencv_ort_configure_findings "${_fx}/nolog" "${_cache}" "${_compat}" "${_chain}" 1.30.0)" "configure log missing"
t_assert_contains "$(opencv_ort_configure_findings "${_log}" "${_fx}/nocache" "${_compat}" "${_chain}" 1.30.0)" "CMakeCache.txt missing"

# The install tree dnn's install rule writes: a real copy of the chain file plus its soname links.
_prefix="${_fx}/opencv5"
_install_copy() {
  rm -rf "${_prefix}"; mkdir -p "${_prefix}/lib"
  cp "${_chain}/lib/libonnxruntime.so.1.30.0" "${_prefix}/lib/"
  ln -s libonnxruntime.so.1.30.0 "${_prefix}/lib/libonnxruntime.so.1"
  touch "${_prefix}/lib/libopencv_dnn.so.500"
}

t_case "opencv install gate: dnn's copies become links into the chain, and nothing else"
_install_copy
t_assert_contains "$(opencv_ort_install_findings "${_prefix}" "${_chain}/lib")" "COPY ${_prefix}/lib/libonnxruntime.so.1.30.0"
t_assert_ok opencv_ort_forward_installed "${_prefix}" "${_chain}/lib"
t_assert_eq "" "$(opencv_ort_install_findings "${_prefix}" "${_chain}/lib")"
t_assert_eq "$(readlink -f "${_chain}/lib/libonnxruntime.so.1.30.0")" "$(readlink -f "${_prefix}/lib/libonnxruntime.so.1")"
t_assert_ok test -f "${_prefix}/lib/libopencv_dnn.so.500"

t_case "opencv install gate: bytes the chain does not have are refused, not forwarded"
_install_copy
printf 'microsoft-ort-1.25.1' > "${_prefix}/lib/libonnxruntime.so.1.30.0"
t_assert_eq "1" "$(t_rc opencv_ort_forward_installed "${_prefix}" "${_chain}/lib")"
t_assert_contains "$(t_out opencv_ort_forward_installed "${_prefix}" "${_chain}/lib")" "foreign ORT"
_install_copy
printf 'x' > "${_prefix}/lib/libonnxruntime.so.1.25.1"
t_assert_contains "$(t_out opencv_ort_forward_installed "${_prefix}" "${_chain}/lib")" "no chain counterpart"

t_case "opencv install gate: a link elsewhere or a dead link is a finding"
rm -rf "${_prefix}"; mkdir -p "${_prefix}/lib"
ln -s "${_foreign}/lib/libonnxruntime.so" "${_prefix}/lib/libonnxruntime.so"
ln -s "${_chain}/lib/libonnxruntime.so.9" "${_prefix}/lib/libonnxruntime.so.9"
_out="$(opencv_ort_install_findings "${_prefix}" "${_chain}/lib")"
t_assert_contains "${_out}" "installed='${_prefix}/lib/libonnxruntime.so' resolves to '$(readlink -f "${_foreign}/lib/libonnxruntime.so")'"
t_assert_contains "${_out}" "installed='${_prefix}/lib/libonnxruntime.so.9' does not exist"

t_case "opencv: build-opencv.sh wires the tree, the args and both gates, each fatal"
# Continuation lines joined, so `call \<newline> || die` reads as one line.
_flat() { t_fn_src "${OCV}" "$1" | sed -e ':a' -e '/\\$/{N;s/[[:space:]]*\\\n[[:space:]]*/ /;ba}'; }
_cfgfn="$(_flat configure_opencv)"
_insfn="$(_flat install_opencv)"
t_assert_contains "$(cat "${OCV}")" 'source "${SCRIPT_DIR}/opencv-ort.sh"'
t_assert_contains "${_cfgfn}" 'opencv_ort_compat_tree "${OPENCV_ORT_CHAIN_ROOT}" "${ort_compat}" || die'
t_assert_contains "${_cfgfn}" 'ort_ver="$(opencv_ort_version "${OPENCV_ORT_CHAIN_ROOT}/lib")" || die'
t_assert_contains "${_cfgfn}" 'opencv_ort_cmake_args cmake_opts "${ort_compat}" "${ort_ver}"'
t_assert_contains "${_cfgfn}" '| tee "${build_dir}/opencv-configure.log" || die'
t_assert_contains "${_cfgfn}" 'opencv_ort_assert_configure "${build_dir}" "${ort_compat}" "${ort_ver}" || die'
t_assert_contains "${_insfn}" 'opencv_ort_assert_installed "${OPENCV_PREFIX}" || die'

# ── FFmpeg ───────────────────────────────────────────────────────────────────
# n9.0.2 configure: `require libonnxruntime onnxruntime_c_api.h OrtGetApiBase -lonnxruntime`, no pkg-config.
FF="${MEDIA}/ffmpeg/build-ffmpeg.sh"
# One probe run in a child shell: $1 chain root, $2 ok|fail for the stubbed synth probe.
_ff_probe() {
  FF_SYNTH="$2" bash -c '
    set -uo pipefail
    source "$1"
    ffmpeg_probe_pkg_config_feature() { echo "VENDOR-PROBE-CALLED"; return 0; }
    ffmpeg_enable_via_synth_pkgconfig() { [ "${FF_SYNTH}" = ok ]; }
    ffmpeg_probe_libonnxruntime "$2"
    echo "RC=$? ROOT=${_FFMPEG_ONNX_ROOT:-} EXTRA=${_FFMPEG_ONNX_EXTRA_LDFLAGS:-}"' _ "${DNN}" "$1" 2>&1
}

t_case "ffmpeg: a missing chain is fatal, and no vendor .pc is probed"
_out="$(_ff_probe "${_fx}/nochain" ok)"
t_assert_contains "${_out}" "chain ONNX Runtime missing"
t_assert_fails grep -q -e 'VENDOR-PROBE-CALLED' -e 'RC=' <<< "${_out}"
t_assert_eq "0" "$(grep -c -e 'ffmpeg_probe_pkg_config_feature "libonnxruntime"' "${DNN}" || true)" \
  "the vendor-pkg-config fallback is gone"

t_case "ffmpeg: a chain that probes clean enables the backend from the chain"
_out="$(_ff_probe "${_chain}" ok)"
t_assert_contains "${_out}" "RC=0 ROOT=${_chain} EXTRA=-L${_chain}/lib"

t_case "ffmpeg: a chain the probe cannot link is fatal, never a build without ORT"
_out="$(_ff_probe "${_chain}" fail)"
t_assert_contains "${_out}" "does not compile and link for this target"
t_assert_fails grep -q -e 'VENDOR-PROBE-CALLED' -e 'RC=' <<< "${_out}"

# shellcheck source=../03-media/build/ffmpeg/ffmpeg-dnn-backends.sh
source "${DNN}"
t_case "ffmpeg: the chain -L goes ahead of the cross multiarch -L, exactly once"
_opts=(--prefix=/opt/ffmpeg "--extra-ldflags=--sysroot=/" "--extra-ldflags=-L/usr/lib/riscv64-linux-gnu -L/lib/riscv64-linux-gnu"
  --extra-cflags=-I/usr/include "--extra-ldflags=-L${_chain}/lib")
_FFMPEG_ONNX_EXTRA_LDFLAGS="-L${_chain}/lib"
t_assert_ok ffmpeg_ort_ldflags_first _opts
t_assert_eq "--extra-ldflags=-L${_chain}/lib" "$(printf '%s\n' "${_opts[@]}" | grep -m1 -e '^--extra-ldflags=')"
t_assert_eq "1" "$(printf '%s\n' "${_opts[@]}" | grep -cxF -e "--extra-ldflags=-L${_chain}/lib")"
t_assert_eq "5" "${#_opts[@]}"
_opts=(--prefix=/opt/ffmpeg)
ffmpeg_ort_ldflags_first _opts
t_assert_eq "--prefix=/opt/ffmpeg --extra-ldflags=-L${_chain}/lib" "${_opts[*]}" "no other ldflags: appended"
_FFMPEG_ONNX_EXTRA_LDFLAGS=""
t_assert_fails ffmpeg_ort_ldflags_first _opts
unset _FFMPEG_ONNX_EXTRA_LDFLAGS

t_case "ffmpeg: build-ffmpeg.sh's DNN step puts the chain -L before the cross -L it already holds"
_dnnfn="$(t_fn_src "${FF}" _ffmpeg_probe_dnn_backends)" || exit 1
_out="$(bash -c 'source "$1"; eval "$2"
  ffmpeg_probe_libonnxruntime() { _FFMPEG_ONNX_EXTRA_LDFLAGS="-L/chain/lib"; _FFMPEG_ONNX_EXTRA_LIBS="-lstdc++"; }
  is_truthy() { return 1; }; ffmpeg_probe_libopenvino() { return 1; }; die() { echo "DIE $*"; exit 1; }
  o=("--extra-ldflags=--sysroot=/" "--extra-ldflags=-L/usr/lib/aarch64-linux-gnu")
  _ffmpeg_probe_dnn_backends o; printf "%s\n" "${o[@]}"' _ "${DNN}" "${_dnnfn}" 2>&1)"
t_assert_eq "--extra-ldflags=-L/chain/lib" "$(grep -m1 -e '^--extra-ldflags=' <<< "${_out}")"
t_assert_contains "${_out}" "--enable-libonnxruntime"

# ffbuild/config.mak the way FFmpeg's configure writes it; a distro ORT in the cross multiarch dir.
_ffsrc="${_fx}/ffsrc"
_mak_f="${_ffsrc}/ffbuild/config.mak"
_multi="${_fx}/usr-lib-triplet"
mkdir -p "${_ffsrc}/ffbuild" "${_ffsrc}/rel" "${_multi}" "${_fx}/static" "${_chain}/lib/static"
printf 'ubuntu-ort-1.23' > "${_multi}/libonnxruntime.so"
printf 'ubuntu-ort-1.23' > "${_ffsrc}/rel/libonnxruntime.so"
printf 'x' > "${_fx}/static/libonnxruntime.a"
printf 'x' > "${_chain}/lib/static/libonnxruntime.a"
# _mak <LDFLAGS> <EXTRALIBS-avfilter> [<CONFIG line>]
_mak() {
  printf '%s\n' "SHFLAGS=-shared -Wl,-soname,\$\$(@F)" "LDFLAGS=$1" "LDEXEFLAGS=" "LDSOFLAGS=" \
    "EXTRALIBS-avfilter=$2" "EXTRALIBS=-lm -lstdc++" "${3:-CONFIG_LIBONNXRUNTIME=yes}" > "${_mak_f}"
}
_ffl() { LIBRARY_PATH="${1:-}" ffmpeg_ort_link_findings "${_mak_f}" "${_chain}"; }
_notchain() { printf "LIB %s -> '%s' is not in the chain lib dir" "$1" "$(readlink -f "$2")"; }

t_case "ffmpeg link gate: the hoisted order (chain -L first) is clean"
_mak "-L${_chain}/lib --sysroot=/ -L${_multi} -L/lib/x" "-lonnxruntime -lstdc++ -lm"
t_assert_eq "" "$(_ffl)"

t_case "ffmpeg link gate: the cross multiarch -L ahead of the chain takes the distro ORT (the pre-fix order)"
_mak "--sysroot=/ -L${_multi} -L${_chain}/lib" "-lonnxruntime"
t_assert_contains "$(_ffl)" "$(_notchain -lonnxruntime "${_multi}/libonnxruntime.so")"

t_case "ffmpeg link gate: -L applies to every -l in link-line order, LDFLAGS before EXTRALIBS"
_mak "-L${_chain}/lib" "-L${_multi} -lonnxruntime"
t_assert_eq "" "$(_ffl)"
_mak "" "-L${_multi} -lonnxruntime -L${_chain}/lib"
t_assert_contains "$(_ffl)" "$(_notchain -lonnxruntime "${_multi}/libonnxruntime.so")"

t_case "ffmpeg link gate: the '-L dir', '-L=dir' and relative spellings are walked too"
_mak "-L ${_multi} -L${_chain}/lib" "-lonnxruntime"
t_assert_contains "$(_ffl)" "$(_notchain -lonnxruntime "${_multi}/libonnxruntime.so")"
_mak "-L=${_multi} -L${_chain}/lib" "-lonnxruntime"
t_assert_contains "$(_ffl)" "$(_notchain -lonnxruntime "${_multi}/libonnxruntime.so")"
_mak "-Lrel -L${_chain}/lib" "-lonnxruntime"
t_assert_contains "$(_ffl)" "$(_notchain -lonnxruntime "${_ffsrc}/rel/libonnxruntime.so")"

t_case "ffmpeg link gate: ld's .so-before-.a per dir, and a static ORT anywhere is a finding"
touch "${_chain}/lib/libonnxruntime.a"
_mak "-L${_chain}/lib" "-lonnxruntime"
t_assert_eq "" "$(_ffl)" "the chain dir holds both: ld takes the .so"
rm -f "${_chain}/lib/libonnxruntime.a"
_mak "-L${_chain}/lib/static -L${_chain}/lib" "-lonnxruntime"
t_assert_contains "$(_ffl)" "is a static ORT, not the chain's shared one"
_mak "-L${_fx}/static -L${_chain}/lib" "-lonnxruntime"
t_assert_contains "$(_ffl)" "$(_notchain -lonnxruntime "${_fx}/static/libonnxruntime.a")"

t_case "ffmpeg link gate: -l:<name>, a library path and LIBRARY_PATH resolve as ld does"
_mak "-L${_multi} -L${_chain}/lib" "-l:libonnxruntime.so.1"
t_assert_eq "" "$(_ffl)" "the multiarch dir has no .so.1, so ld goes on to the chain"
_mak "" "${_multi}/libonnxruntime.so"
t_assert_contains "$(_ffl)" "$(_notchain "${_multi}/libonnxruntime.so" "${_multi}/libonnxruntime.so")"
_mak "" "-lonnxruntime"
t_assert_contains "$(_ffl)" "LIB -lonnxruntime -> 'unresolved'"
t_assert_eq "" "$(_ffl "${_fx}/nothere:${_chain}/lib")" "LIBRARY_PATH is the walk's tail"

t_case "ffmpeg link gate: not enabled, not linked, no config.mak or no chain fails closed"
_mak "-L${_chain}/lib" "-lonnxruntime" "!CONFIG_LIBONNXRUNTIME=yes"
t_assert_contains "$(_ffl)" "FFmpeg did not enable libonnxruntime"
_mak "-L${_chain}/lib" "-lm"
t_assert_contains "$(_ffl)" "no link variable names libonnxruntime"
t_assert_contains "$(ffmpeg_ort_link_findings "${_fx}/none.mak" "${_chain}")" "no ${_fx}/none.mak"
t_assert_contains "$(ffmpeg_ort_link_findings "${_mak_f}" "")" "no chain lib dir"

t_case "ffmpeg: configure_ffmpeg runs the link gate after configure, and a finding dies"
_cfgff="$(t_fn_src "${FF}" configure_ffmpeg)" || exit 1
printf '#!/bin/sh\nexit 0\n' > "${_ffsrc}/configure"
chmod +x "${_ffsrc}/configure"
_ff_cfg() {
  FFMPEG_SRC="${_ffsrc}" FFMPEG_PREFIX=/opt/ffmpeg bash -c 'source "$1"; eval "$2"
    for f in _ffmpeg_cross_args _ffmpeg_probe_core_codecs _ffmpeg_probe_dnn_backends _ffmpeg_probe_extra_pkgconfig_loop \
        _ffmpeg_probe_extra_link_loop _ffmpeg_hwaccel_args _ffmpeg_linker_ccache_args; do eval "${f}() { :; }"; done
    is_truthy() { return 1; }; die() { echo "DIE $*"; exit 1; }
    _FFMPEG_ONNX_ROOT="$3"; configure_ffmpeg; echo SURVIVED' _ "${DNN}" "${_cfgff}" "${_chain}" 2>&1
}
_mak "-L${_chain}/lib" "-lonnxruntime"
t_assert_contains "$(_ff_cfg)" "SURVIVED"
_mak "-L${_multi} -L${_chain}/lib" "-lonnxruntime"
_out="$(_ff_cfg)"
t_assert_contains "${_out}" "DIE FFmpeg links an ONNX Runtime other than the chain"
t_assert_fails grep -q -e SURVIVED <<< "${_out}"

# ── GStreamer onnx plugin ────────────────────────────────────────────────────
# shellcheck source=../03-media/build/gstreamer/common/gst-onnx-ort.sh
source "${GST_ORT}"
_bdir="${_fx}/gst/builddir"
mkdir -p "${_bdir}"
# Meson's build.ninja for gstonnx: one link and one compile statement ($1 = LINK_ARGS, $2 = ARGS).
_ninja() {
  printf '%s\n' "rule c_LINKER" " command = cc" "" \
    "build subprojects/gst-plugins-bad/ext/onnx/libgstonnx.so.p/gstonnxinference.c.o: c_COMPILER ../x.c" \
    " ARGS = -Isubprojects/gst-plugins-bad/ext/onnx $2" "" \
    "build subprojects/gst-plugins-bad/ext/onnx/libgstonnx.so: c_LINKER subprojects/gst-plugins-bad/ext/onnx/libgstonnx.so.p/gstonnxinference.c.o" \
    " LINK_ARGS = -Wl,--as-needed -shared -Wl,-rpath,${_chain}/lib $1" "" \
    "build subprojects/other/libother.so: c_LINKER x.o" " LINK_ARGS = ${_foreign}/lib/libonnxruntime.so" \
    > "${_bdir}/build.ninja"
}
_gst() { LIBRARY_PATH="${1:-}" gst_onnx_ort_findings "${_bdir}/build.ninja" "${_bdir}" "${_chain}" "${_fx}/no-gpu"; }

t_case "gst onnx: the chain via pkg-config (absolute lib, chain -I) is clean; other targets are not judged"
_ninja "-L${_chain}/lib ${_chain}/lib/libonnxruntime.so" "-I${_chain}/include -I${_chain}/include/onnxruntime/core/session"
t_assert_eq "" "$(_gst)"

t_case "gst onnx: a foreign library, by path or through the -L walk, is caught"
_ninja "${_foreign}/lib/libonnxruntime.so" "-I${_chain}/include"
t_assert_contains "$(_gst)" "LIB ${_foreign}/lib/libonnxruntime.so"
_ninja "-L${_foreign}/lib -L${_chain}/lib -lonnxruntime" "-I${_chain}/include"
t_assert_contains "$(_gst)" "LIB -lonnxruntime -> '$(readlink -f "${_foreign}/lib/libonnxruntime.so")'"
_ninja "-lonnxruntime" "-I${_chain}/include"
t_assert_eq "" "$(_gst "${_fx}/nothere:${_chain}/lib")" "LIBRARY_PATH is the walk's tail, as for ld"
t_assert_contains "$(_gst "${_fx}/nothere")" "LIB -lonnxruntime -> 'unresolved'"

t_case "gst onnx: a link that names no ORT at all is a finding, not a pass"
_ninja "-Wl,--as-needed" "-I${_chain}/include"
t_assert_contains "$(_gst)" "names no ONNX Runtime library at all"

t_case "gst onnx: headers must come from the chain include tree, and from somewhere"
_ninja "${_chain}/lib/libonnxruntime.so" "-isystem ${_foreign}/include -I${_chain}/include"
t_assert_contains "$(_gst)" "HDR ${_foreign}/include provides onnxruntime_c_api.h"
_ninja "${_chain}/lib/libonnxruntime.so" "-I../nothing"
t_assert_contains "$(_gst)" "HDR no include dir"
mkdir -p "${_fx}/gst/rel"; ln -s "${_chain}/include" "${_fx}/gst/rel/ort"
_ninja "${_chain}/lib/libonnxruntime.so" "-I../rel/ort"
t_assert_eq "" "$(_gst)" "a relative -I is read against meson's builddir"

t_case "gst onnx: no build.ninja or no gstonnx statement fails closed"
t_assert_contains "$(gst_onnx_ort_findings "${_fx}/none.ninja" "${_bdir}" "${_chain}")" "no ${_fx}/none.ninja"
printf '%s\n' "build a.o: c_COMPILER a.c" > "${_bdir}/build.ninja"
t_assert_contains "$(_gst)" "no link statement for libgstonnx.so"

t_case "gst onnx: the gate runs between meson setup and compile, and a finding exits"
_mainfn="$(t_fn_src "${GST}" build_gstreamer_monorepo)" || exit 1
t_assert_contains "${_mainfn}" "$(printf '%s\n  %s\n  %s' _gst_monorepo_meson_setup_run _gst_monorepo_onnx_ort_gate _gst_monorepo_compile)"
_gatefn="$(t_fn_src "${GST}" _gst_monorepo_onnx_ort_gate)" || exit 1
_rc="$(bash -c "gst_onnx_ort_findings() { echo 'LIB x'; }; ${_gatefn}
_gst_monorepo_onnx_ort_gate; echo SURVIVED" 2>&1)"
t_assert_contains "${_rc}" "reaches an ONNX Runtime outside the chain"
t_assert_fails grep -q -e SURVIVED <<< "${_rc}"

t_summary
