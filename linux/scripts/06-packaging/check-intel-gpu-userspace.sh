#!/usr/bin/env bash
# Intel's GPU user space in an amd64 image, graded by file presence only; no Intel device runs here. docs/linux-accelerator-images.md#intel-gpu-user-space

# Sourced by smoke-runtime-image.sh; sets no shell options.

# amd64 only: the VA driver, Quick Sync runtime and OpenCL ICD the package stage installs, and FFmpeg's Quick Sync codecs.
_probe_intel_gpu_userspace() {
  cat <<'PROBE'
if [ -x /lib64/ld-linux-x86-64.so.2 ]; then
  for _f in va:/usr/lib/x86_64-linux-gnu/dri/iHD_drv_video.so qsv:/usr/lib/x86_64-linux-gnu/libmfx-gen.so.1.2 opencl:/etc/OpenCL/vendors/intel.icd; do
    if [ -e "${_f#*:}" ]; then printf 'INTELGPU %s present\n' "${_f%%:*}"; else printf 'INTELGPU %s absent\n' "${_f%%:*}"; fi
  done
  if [ "$(/opt/ffmpeg/bin/ffmpeg -hide_banner -encoders 2>/dev/null | grep -c -e h264_qsv)" != 0 ]; then
    printf 'INTELGPU ffmpeg-qsv present\n'; else printf 'INTELGPU ffmpeg-qsv absent\n'; fi
fi
PROBE
}

# One OK|BAD <part> <state> line per part the probe looked for.
_intel_gpu_userspace_verdicts() {
  local probe="$1" part state n=0
  while read -r part state; do
    [ -n "${part}" ] || continue
    n=$((n + 1))
    if [ "${state}" = present ]; then printf 'OK %s present\n' "${part}"; else printf 'BAD %s %s\n' "${part}" "${state:-unread}"; fi
  done < <(_smoke_probe_values "${probe}" INTELGPU)
  [ "${n}" -gt 0 ] || printf 'NONE - -\n'
}

_intel_gpu_userspace_verdict_line() {
  _shipped_verdict_line "$1" \
    "Intel GPU user space: @1@ is @2@ in this amd64 image; the package stage installs the drivers and build-ffmpeg.sh enables Quick Sync. See docs/linux-accelerator-images.md#intel-gpu-user-space" \
    "" \
    "Intel GPU user space: the probe printed no INTELGPU line -- a vacuous pass, not a green image"
}

# C3: an amd64 image without Intel's drivers or FFmpeg's Quick Sync codecs lost them silently at install or configure time.
check_intel_gpu_userspace() {
  _shipped_arch_gate amd64 "$2" "C3: Intel GPU user space in the amd64 image" "Intel GPU user-space" \
    "Intel GPU user space: " " part(s) present" _intel_gpu_userspace_verdicts _intel_gpu_userspace_verdict_line
}
