#!/usr/bin/env bash
# The Intel GPU user-space gate on probe lines and the package list; no package is installed and no Intel device runs. docs/linux-accelerator-images.md#intel-gpu-user-space
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
PKG="${TESTS_DIR}/../06-packaging"
SMOKE="${PKG}/smoke-runtime-image.sh"
GATE="${PKG}/check-intel-gpu-userspace.sh"

eval "$(t_fn_src "${SMOKE}" _smoke_probe_values)"
eval "$(t_fn_src "${PKG}/smoke-common.sh" _shipped_verdict_line)"
eval "$(t_fn_src "${PKG}/smoke-common.sh" _shipped_arch_gate)"
for _fn in _probe_intel_gpu_userspace _intel_gpu_userspace_verdicts _intel_gpu_userspace_verdict_line check_intel_gpu_userspace; do
  eval "$(t_fn_src "${GATE}" "${_fn}")"
done
fail() { echo "FAIL $*"; }
_shipped_truth_verdict_gate() { echo "RAN $1"; }
_verdicts() { _intel_gpu_userspace_verdicts "$(printf '%s\n' "$@")"; }

t_case "four parts present are four passes"
_o="$(_verdicts 'INTELGPU va present' 'INTELGPU qsv present' 'INTELGPU opencl present' 'INTELGPU ffmpeg-qsv present')"
t_assert_eq "4" "$(printf '%s\n' "${_o}" | grep -c -e '^OK ')"
t_assert_eq "0" "$(printf '%s\n' "${_o}" | grep -c -e '^BAD ')"

t_case "a missing file is BAD and names the part"
_o="$(_verdicts 'INTELGPU va present' 'INTELGPU qsv absent' 'INTELGPU opencl present')"
t_assert_contains "${_o}" "BAD qsv absent" "a package the index did not have is skipped silently at install time"
t_assert_contains "$(_verdicts 'INTELGPU va')" "BAD va unread" "a line without a state is not a pass"

t_case "a probe without INTELGPU lines is NONE, not a vacuous green"
t_assert_contains "$(_intel_gpu_userspace_verdicts "")" "NONE"
t_assert_contains "$(_verdicts 'X86CC x86-64-v3')" "NONE"

t_case "BAD and NONE fail with the cause, OK is silent"
t_assert_contains "$(_intel_gpu_userspace_verdict_line 'BAD qsv absent')" \
  "FAIL Intel GPU user space: qsv is absent in this amd64 image"
t_assert_contains "$(_intel_gpu_userspace_verdict_line 'NONE - -')" "FAIL Intel GPU user space: the probe printed no INTELGPU line"
t_assert_eq "" "$(_intel_gpu_userspace_verdict_line 'OK va present')"

t_case "the gate runs on amd64 only"
t_assert_contains "$(check_intel_gpu_userspace img amd64)" "RAN Intel GPU user-space gate could not run"
t_assert_eq "" "$(check_intel_gpu_userspace img arm64)" "the packages do not exist on arm64"
t_assert_eq "" "$(check_intel_gpu_userspace img riscv64)"

t_case "the probe looks for the files the three packages ship"
_p="$(_probe_intel_gpu_userspace)"
t_assert_contains "${_p}" "va:/usr/lib/x86_64-linux-gnu/dri/iHD_drv_video.so" "intel-media-va-driver"
t_assert_contains "${_p}" "qsv:/usr/lib/x86_64-linux-gnu/libmfx-gen.so.1.2" "libmfx-gen1.2"
t_assert_contains "${_p}" "opencl:/etc/OpenCL/vendors/intel.icd" "intel-opencl-icd"
t_assert_contains "${_p}" "/opt/ffmpeg/bin/ffmpeg -hide_banner -encoders" "a probe that failed at configure time ships FFmpeg without Quick Sync"
t_assert_contains "${_p}" "grep -c -e h264_qsv" "counted, never grep -q: ffmpeg dies of SIGPIPE under pipefail"
t_assert_ok bash -n <(printf '%s\n' "${_p}")

t_case "the smoke run sources the gate, emits its probe and calls it"
_smoke_src="$(cat "${SMOKE}")"
t_assert_contains "${_smoke_src}" 'source "${_SCRIPT_DIR}/check-intel-gpu-userspace.sh"'
t_assert_contains "${_smoke_src}" "  _probe_intel_gpu_userspace" "a gate without its probe lines reads NONE"
t_assert_contains "${_smoke_src}" 'check_intel_gpu_userspace "${image_tag}" "${target_arch}"' "an unwired gate is not a gate"

t_case "the package stage asks for the free builds, never the multiverse driver"
_pkg_src="$(cat "${PKG}/setup-package-image.sh")"
t_assert_contains "${_pkg_src}" "append_available_packages _sdp_out intel-media-va-driver libmfx-gen1.2 intel-opencl-icd"
t_assert_eq "0" "$(printf '%s\n' "${_pkg_src}" | grep -c -e 'intel-media-va-driver-non-free')" "owner decision 2026-11-12"

# ── FFmpeg: Quick Sync through libvpl, amd64 only ────────────────────────────
FFMPEG="${TESTS_DIR}/../03-media/build/ffmpeg"
_hw_fn="$(t_fn_src "${FFMPEG}/build-ffmpeg.sh" _ffmpeg_hwaccel_args)" || exit 1
_hw_args() {  # <arch> <probes that pass, space-separated>: the options, one per line
  CUDA_HOME=/nonexistent ENABLE_NVIDIA=false bash -c 'set -euo pipefail; _arch="$2"; _pass=" $3 "
    cross_target_arch() { printf "%s" "${_arch}"; }
    ffmpeg_probe_vdpau() { return 1; }
    ffmpeg_probe_pkg_config_feature() { echo "PROBE $*" >&2; case "${_pass}" in *" $1 "*) return 0 ;; esac; return 1; }
    eval "$1"; opts=(); _ffmpeg_hwaccel_args opts; printf "%s\n" "${opts[@]}"' _ "${_hw_fn}" "$1" "$2"
}

t_case "amd64 enables libvpl when FFmpeg's own check would pass, and asks with its arguments"
t_assert_contains "$(_hw_args amd64 'vaapi libvpl' 2>/dev/null)" "--enable-libvpl"
t_assert_contains "$(_hw_args amd64 'vaapi libvpl' 2>&1)" "PROBE libvpl vpl >= 2.6 mfxvideo.h mfxdispatcher.h MFXLoad" \
  "FFmpeg 9.0.2 configure: check_pkg_config libmfx \"vpl >= 2.6\" \"mfxvideo.h mfxdispatcher.h\" MFXLoad"

t_case "a failed probe or another arch leaves it off instead of failing configure"
t_assert_eq "0" "$(_hw_args amd64 'vaapi' 2>/dev/null | grep -c -e '--enable-libvpl')" "the image gate reports the gap"
t_assert_eq "0" "$(_hw_args arm64 'vaapi libvpl' 2>/dev/null | grep -c -e '--enable-libvpl')"
t_assert_eq "0" "$(_hw_args riscv64 'vaapi libvpl' 2>/dev/null | grep -c -e '--enable-libvpl')"

t_case "the dispatcher is installed for the build and mapped for the runtime"
t_assert_contains "$(cat "${FFMPEG}/install-deps.sh")" "install_optional_target_packages libvpl-dev"
t_assert_eq "1" "$(grep -c -e "^libvpl\.so\.2$(printf '\t')libvpl2$" "${TESTS_DIR}/../03-media/runtime/so-package-map.txt")" \
  "FFmpeg's new NEEDED entry must resolve to a package in the runtime image"

t_summary
