#!/usr/bin/env bash
# DeepStream gates without a GPU (closure, one GStreamer, no libv4l2 hijack, registration); not covered: inference, NVDEC, engine builds.
set -uo pipefail

DS_ROOT="${DS_ROOT:-/opt/nvidia/deepstream/deepstream-9.1}"
DS_TRT_PREFIX="${DS_TRT_PREFIX:-}"
GSTREAMER_PREFIX="${GSTREAMER_PREFIX:-/opt/gstreamer}"

# The display driver provides these on a GPU host (nvidia-container-toolkit injects them).
DSV_DRIVER_SONAMES=(libcuda.so.1 libnvidia-ml.so.1)

# "<file under DS_ROOT>|<soname>|<why it may stay unresolved>"; an entry that no longer matches fails as stale.
DSV_ALLOWED_MISSING=(
  "lib/gst-plugins/libnvdsgst_ucx.so|libucs.so.0|UCX: Ubuntu's libucx0 depends on ROCm's HIP runtime"
  "lib/gst-plugins/libnvdsgst_ucx.so|libucp.so.0|UCX: Ubuntu's libucx0 depends on ROCm's HIP runtime"
  "lib/libnvds_3d_dataloader_realsense.so|librealsense2.so|Intel RealSense SDK, not shipped"
  "lib/libnvdsgst_sparse4d.so|libtorch.so|libtorch lives in the app venv, not on the loader path"
  "lib/libnvdsgst_sparse4d.so|libtorch_cpu.so|libtorch lives in the app venv, not on the loader path"
  "lib/libnvdsgst_sparse4d.so|libc10.so|libtorch lives in the app venv, not on the loader path"
  "lib/libnvdsgst_aigshelper.so|libNVCVImage.so|NVIDIA Maxine (NVCV), not distributed with DeepStream"
  "lib/libnvdsgst_sparse4d.so|libnvds_meta.so|NVIDIA's RUNPATH names deepstream-9.0; it cannot load without libtorch anyway"
  "lib/libnvdsgst_sparse4d.so|libnvdsbufferpool.so|NVIDIA's RUNPATH names deepstream-9.0; it cannot load without libtorch anyway"
  "lib/libnvdsgst_sparse4d.so|libnvdsgst_helper.so|NVIDIA's RUNPATH names deepstream-9.0; it cannot load without libtorch anyway"
  "lib/libnvds_tritoninferfilter.so|libnvds_infer_server.so|Triton: nvdsinferserver is not built"
)

DSV_ELEMENTS=(nvinfer nvstreammux nvvideoconvert nvtracker nvdsosd nvv4l2decoder nvmultistreamtiler nvstreamdemux nvurisrcbin)

dsv_fail=0
dsv_bad() { printf '  FAIL %s\n' "$*"; dsv_fail=1; }
dsv_ok() { printf '  ok   %s\n' "$*"; }

# stdin: "<file> <soname>" per unresolved soname; prints BROKEN for an unexcused one and STALE for an unused excuse.
dsv_closure_verdict() {
  local file soname e d f n
  local -A used=()
  while read -r file soname; do
    [ -n "${file}" ] || continue
    for d in "${DSV_DRIVER_SONAMES[@]}"; do [ "${soname}" = "${d}" ] && continue 2; done
    for e in "${DSV_ALLOWED_MISSING[@]}"; do
      IFS='|' read -r f n _ <<< "${e}"
      if [ "${f}|${n}" = "${file}|${soname}" ]; then used["${f}|${n}"]=1; continue 2; fi
    done
    printf 'BROKEN %s -> %s\n' "${file}" "${soname}"
  done
  for e in "${DSV_ALLOWED_MISSING[@]}"; do
    IFS='|' read -r f n _ <<< "${e}"
    [ -n "${used[${f}|${n}]:-}" ] || printf 'STALE %s -> %s (allowed missing, but it resolves or the file is gone)\n' "${f}" "${n}"
  done
  return 0
}

# "<file under DS_ROOT> <soname> <path|NOTFOUND>" for every ELF, as the loader alone sees it: no LD_LIBRARY_PATH.
dsv_ldd_table() {
  local f
  while IFS= read -r f; do
    env -u LD_LIBRARY_PATH ldd "${f}" 2>/dev/null | awk -v f="${f#"${DS_ROOT}"/}" \
      '$2=="=>" && $3=="not" {print f, $1, "NOTFOUND"; next} $2=="=>" && $3 ~ /^\// {print f, $1, $3}'
  done < <(find "$@" -name '*.so*' -type f | LC_ALL=C sort)
}

dsv_unresolved() {
  dsv_ldd_table "${DS_ROOT}/lib" ${DS_TRT_PREFIX:+"${DS_TRT_PREFIX}/lib"} | awk '$3=="NOTFOUND"{print $1, $2}'
}

dsv_check_closure() {
  local verdict
  verdict="$(dsv_unresolved | LC_ALL=C sort -u | dsv_closure_verdict)"
  if [ -n "${verdict}" ]; then
    printf '%s\n' "${verdict}" | while IFS= read -r l; do printf '    %s\n' "${l}"; done
    dsv_bad "soname closure"
  else
    dsv_ok "soname closure (driver sonames and ${#DSV_ALLOWED_MISSING[@]} documented exceptions aside)"
  fi
}

# stdin: "<file> <soname> <resolved path>"; prints each GStreamer/GLib soname resolved outside the one allowed prefix.
dsv_gst_origin_verdict() {
  local file soname path
  while read -r file soname path; do
    case "${soname}" in
      libgst*-1.0.so.0|liborc-0.4.so.0)
        case "${path}" in "${GSTREAMER_PREFIX}"/*) ;; *) printf 'SECOND-GSTREAMER %s -> %s => %s\n' "${file}" "${soname}" "${path}" ;; esac ;;
    esac
  done
  return 0
}

dsv_check_one_gstreamer() {
  local verdict provides
  verdict="$(dsv_ldd_table "${DS_ROOT}/lib/gst-plugins" | dsv_gst_origin_verdict)"
  provides="$(find "${DS_ROOT}" -name 'libgst*-1.0.so*' -o -name 'libgstreamer-1.0.so*' | head -5)"
  [ -z "${provides}" ] || verdict+=$'\n'"DeepStream tree ships a GStreamer core library: ${provides}"
  if [ -n "${verdict//[[:space:]]/}" ]; then printf '    %s\n' "${verdict}"; dsv_bad "one GStreamer (${GSTREAMER_PREFIX})"; else dsv_ok "every plugin resolves GStreamer from ${GSTREAMER_PREFIX}"; fi
}

# libnvv4l2.so carries SONAME libv4l2.so.0: with its dir in ld.so.conf, ldconfig would hand it to every V4L2 user.
dsv_check_no_v4l2_hijack() {
  local hit
  hit="$(grep -lsF "${DS_ROOT}/lib" /etc/ld.so.conf.d/*.conf 2>/dev/null || true)"
  [ -z "${hit}" ] || { dsv_bad "${DS_ROOT}/lib is on the loader path (${hit}); libnvv4l2.so would shadow libv4l2.so.0"; return 0; }
  hit="$(ldconfig -p 2>/dev/null | awk '$1=="libv4l2.so.0"{print $NF}' | grep -F /opt/nvidia || true)"
  [ -z "${hit}" ] || { dsv_bad "ldconfig resolves libv4l2.so.0 to ${hit}"; return 0; }
  dsv_ok "libv4l2.so.0 stays the distro's"
}

dsv_non_plugins() {
  local f
  for f in "$1"/*.so; do
    [ -e "${f}" ] || continue
    # No grep -q: its early exit SIGPIPEs nm, and under pipefail a real plugin then reads as a helper.
    nm -D --defined-only "${f}" 2>/dev/null | grep -E ' (gst_plugin_[A-Za-z0-9_]+_get_desc|gst_plugin_desc)$' >/dev/null || printf '%s\n' "${f}"
  done
}

dsv_check_plugin_dir() {
  local n
  n="$(dsv_non_plugins "${DS_ROOT}/lib/gst-plugins" | xargs -r -n1 basename | tr '\n' ' ')"
  if [ -n "${n}" ]; then dsv_bad "non-plugin libraries in gst-plugins/ (the registry scan dlclose()s them): ${n}"; else dsv_ok "gst-plugins/ holds only plugins"; fi
}

# The driver stand-ins: CUDA's stub libcuda/libnvidia-ml answer every call with an error, which is enough to register.
dsv_driver_stubs() {
  local d="$1" stubs="${CUDA_HOME:-/usr/local/cuda}/lib64/stubs"
  mkdir -p "${d}"
  ln -sf "${stubs}/libcuda.so" "${d}/libcuda.so.1"
  ln -sf "${stubs}/libnvidia-ml.so" "${d}/libnvidia-ml.so.1"
}

# DSV_WIRED=1 (the package) finds the plugins only through the image's own plugin path; the build stage names the dir.
dsv_gst_env() {
  local stubs="$1" path="${GST_PLUGIN_PATH:-}"
  [ "${DSV_WIRED:-0}" = 1 ] || path="${DS_ROOT}/lib/gst-plugins${path:+:${path}}"
  printf 'LD_LIBRARY_PATH=%s\nGST_PLUGIN_PATH=%s\nGST_REGISTRY=%s\n' "${stubs}" "${path}" "${stubs%/*}/registry.bin"
}

dsv_check_elements() {
  local tmp e file out
  local -a genv=()
  tmp="$(mktemp -d)"
  dsv_driver_stubs "${tmp}/stubs"
  mapfile -t genv < <(dsv_gst_env "${tmp}/stubs")
  out="$(env "${genv[@]}" gst-inspect-1.0 -b 2>&1)"
  if printf '%s' "${out}" | grep -q 'segmentation fault'; then dsv_bad "the registry scan crashed: $(printf '%s' "${out}" | grep -A1 'segmentation fault' | tr '\n' ' ')"; fi
  for e in "${DSV_ELEMENTS[@]}"; do
    file="$(env "${genv[@]}" gst-inspect-1.0 "${e}" 2>/dev/null | awk '/^  Filename/{print $2}')"
    file="$(readlink -f "${file:-/nonexistent}" 2>/dev/null || true)"
    case "${file}" in
      "${DS_ROOT}"/lib/gst-plugins/*) dsv_ok "${e} registers (${file##*/})" ;;
      *) dsv_bad "${e} does not register from ${DS_ROOT}/lib/gst-plugins (got '${file}')" ;;
    esac
  done
  rm -rf "${tmp}"
}

dsv_main() {
  [ -d "${DS_ROOT}/lib/gst-plugins" ] || { printf 'FAIL no DeepStream tree at %s\n' "${DS_ROOT}"; return 1; }
  echo "--- DeepStream gates (${DS_ROOT}) ---"
  dsv_check_plugin_dir
  dsv_check_closure
  dsv_check_one_gstreamer
  dsv_check_no_v4l2_hijack
  dsv_check_elements
  [ "${dsv_fail}" = 0 ] || { echo "DeepStream gates FAILED"; return 1; }
  echo "DeepStream gates passed"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  dsv_main
fi
