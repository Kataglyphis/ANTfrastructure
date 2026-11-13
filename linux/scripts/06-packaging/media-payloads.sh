#!/usr/bin/env bash
# Copy and smoke observation use one optional-payload inventory while retaining their distinct coverage.
media_optional_payloads() {
  cat <<'PAYLOADS'
/usr/local/lib/onnxruntime-genai|observe
/usr/local/lib/onnxruntime-gpu|observe
/usr/local/lib/onnxruntime-ep-amdgpu|observe
/usr/local/lib/onnxruntime-ep-qnn|observe
/usr/local/lib/onnxruntime-ep-tensorrt|observe
/usr/local/include/tflite|observe
/usr/local/include/absl|copy
/usr/local/include/tensorflow|observe
/usr/local/include/flatbuffers|copy
/usr/local/include/c|copy
/usr/local/lib/pkgconfig/litert.pc|observe
/usr/local/lib/pkgconfig/tensorflow-lite.pc|copy
/usr/local/lib/pkgconfig/tensorflowlite_c.pc|copy
/usr/local/lib/pkgconfig/libvvdec.pc|copy
/usr/local/lib/litert-web|copy
/usr/local/lib/litert-lm-web|copy
/usr/local/lib/onnxruntime-web|copy
PAYLOADS
}

# Source MIGraphX precedes the retained distro extras tree without publishing ASAN paths.
media_rocm_library_paths() {
  local rocm_image_root="${1:-}" rocm_found rocm_sorted rocm_library
  local -a rocm_paths=(/opt/rocm/migraphx/lib /opt/rocm/migraphx/lib64)
  local -A rocm_seen=()
  [ -d "${rocm_image_root}/opt/rocm" ] || return 0
  rocm_found="$(find -H "${rocm_image_root}/opt/rocm" \
    -path "${rocm_image_root}/opt/rocm/core-asan-*" -prune -o \
    \( -name 'libamdhip64.so*' -o -name 'libmigraphx_c.so*' \) -printf '%h\n')" || return
  rocm_sorted="$(printf '%s\n' "${rocm_found}" "${rocm_image_root}/opt/rocm/lib" \
    "${rocm_image_root}/opt/rocm/lib64" | LC_ALL=C sort -u)" || return
  while IFS= read -r rocm_library; do
    rocm_paths+=("${rocm_library#"${rocm_image_root}"}")
  done <<< "${rocm_sorted}"
  for rocm_library in "${rocm_paths[@]}"; do
    if [ -n "${rocm_library}" ] && [ -d "${rocm_image_root}${rocm_library}" ] \
      && [ -z "${rocm_seen[${rocm_library}]:-}" ]; then
      printf '%s\n' "${rocm_library}" || return
      rocm_seen["${rocm_library}"]=1
    fi
  done
  return 0
}

# Resolve the full ordered list before replacing a healthy configuration.
publish_rocm_ld_path() {
  local rocm_image_root="${1:-}" rocm_directories
  rocm_directories="$(media_rocm_library_paths "${rocm_image_root}")" || return
  if [ -n "${rocm_directories}" ]; then
    printf '%s\n' "${rocm_directories}" > "${rocm_image_root}/etc/ld.so.conf.d/000-rocm.conf" || return
  else
    rm -f -- "${rocm_image_root}/etc/ld.so.conf.d/000-rocm.conf" || return
  fi
  return 0
}
