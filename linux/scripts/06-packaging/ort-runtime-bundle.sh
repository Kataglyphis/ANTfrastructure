#!/usr/bin/env bash
# ORT_PYTHON_GPU_HOST_IMPORTS_API=1

# The plugin MIGraphX EP's module name and where the rocm image keeps it: docs/consumer-image-contract.md#amds-plugin-migraphx-ep
ORT_AMDGPU_EP_MODULE=libmigraphx-ep.so
ort_amdgpu_ep_dir() { printf '%s/lib' "${ORT_AMDGPU_EP_ROOT:-/usr/local/lib/onnxruntime-ep-amdgpu}"; }
# <capi or lib dir> <cuda|migraphx>: the GPU EP module a bundle carries for that kind.
ort_python_provider_file() {
  case "$2" in
    cuda) printf '%s/libonnxruntime_providers_cuda.so' "$1" ;;
    migraphx) printf '%s/%s' "$1" "${ORT_AMDGPU_EP_MODULE}" ;;
    *) printf 'unknown GPU provider kind: %s\n' "$2" >&2; return 2 ;;
  esac
}

# Stage the selected chain ONNX Runtime and its GPU EP (nvidia: the CUDA plugin EP the GPU ORT builds; amd: the plugin MIGraphX EP beside the CPU ORT); the caller verifies provenance and licenses.

stage_ort_runtime() {
  local ort_dest="${1:?destination required}" ort_dir="${2:?ORT directory required}" ort_variant="${3:?variant required}" ort_file
  local -a ort_files=("${ort_dir}/libonnxruntime.so" "${ort_dir}/libonnxruntime.so.1")
  case "${ort_variant}" in
    cpu) ;;
    nvidia) ort_files+=("${ort_dir}/libonnxruntime_providers_shared.so" "${ort_dir}/libonnxruntime_providers_cuda.so") ;;
    amd) ort_files+=("$(ort_amdgpu_ep_dir)/${ORT_AMDGPU_EP_MODULE}") ;;
    *) printf 'unknown ORT variant: %s\n' "${ort_variant}" >&2; return 2 ;;
  esac
  for ort_file in "${ort_files[@]}"; do
    [ -f "${ort_file}" ] || { printf 'ORT %s variant requires %s\n' "${ort_variant}" "${ort_file}" >&2; return 1; }
  done
  mkdir -p "${ort_dest}" || return
  for ort_file in "${ort_files[@]}"; do cp -L "${ort_file}" "${ort_dest}/${ort_file##*/}" || return; done
}

_ort_host_import_class() {
  local ort_kind="$1" ort_soname="$2"
  case "${ort_soname}" in
    *[!A-Za-z0-9._+-]*) return 1 ;;
    libc.so.6|libm.so.6|libstdc++.so.6|libgcc_s.so.1|libpthread.so.0|libdl.so.2|librt.so.1|ld-linux*.so*) printf 'system\n'; return ;;
  esac
  case "${ort_kind}:${ort_soname}" in
    # The plugin MIGraphX EP links the chain ORT it is loaded into; the bundle carries that.
    migraphx:libonnxruntime.so.1) printf 'system\n' ;;
    cuda:libcuda.so.*|cuda:libcudart.so.*|cuda:libcublas.so.*|cuda:libcublasLt.so.*|cuda:libcurand.so.*|cuda:libcudnn*.so.*|cuda:libcufft*.so.*|cuda:libcusparse.so.*|cuda:libnvrtc.so.*|cuda:libnvJitLink.so.*) printf 'a\n' ;;
    migraphx:libmigraphx_c.so.*) printf 'a\n' ;;
    migraphx:libamdhip64.so.*) printf 'b\n' ;;
    *) return 1 ;;
  esac
}

_ort_host_imports_complete() {
  case "$1:$2:$3" in cuda:1:*|migraphx:1:1) return 0 ;; *) return 1 ;; esac
}

# <kind> <label>: the two GPU EP kinds a bundle can carry; TensorRT is an image-root plugin, never a venv provider.
_ort_require_gpu_kind() {
  case "$1" in cuda|migraphx) return 0 ;; *) printf 'unknown %s: %s\n' "$2" "$1" >&2; return 1 ;; esac
}
_ort_packaging_dir() {
  cd "$(dirname "${BASH_SOURCE[0]}")" || return
  pwd
}

# List the exact vendor SONAMEs a provider leaves to the host; unknown direct imports fail closed.
ort_host_runtime_needed() {
  local ort_provider="${1:?provider library required}" ort_kind="${2:?provider kind required}"
  local ort_dyn ort_soname ort_here ort_class ort_seen_a=0 ort_seen_b=0
  _ort_require_gpu_kind "${ort_kind}" 'GPU provider' || return 2
  ort_here="$(_ort_packaging_dir)" || return 1
  # shellcheck source=linux/scripts/06-packaging/elf-needed.sh
  source "${ort_here}/elf-needed.sh" || return 1
  ort_dyn="$(elf_dynamic_needed "${ort_provider}")" || return 1
  while IFS= read -r ort_soname; do
    [ -n "${ort_soname}" ] || continue
    ort_class="$(_ort_host_import_class "${ort_kind}" "${ort_soname}")" || {
      printf 'unexpected or invalid %s provider dependency: %s\n' "${ort_kind}" "${ort_soname}" >&2; return 1;
    }
    case "${ort_class}" in system) continue ;; a) ort_seen_a=1 ;; b) ort_seen_b=1 ;; esac
    printf '%s\n' "${ort_soname}"
  done <<< "${ort_dyn}"
  if ! _ort_host_imports_complete "${ort_kind}" "${ort_seen_a}" "${ort_seen_b}"; then
    printf '%s provider does not declare its expected host runtime dependencies\n' "${ort_kind}" >&2
    return 1
  fi
}

_ort_validate_python_provider_wheel() {
  local ort_site="${1:?ORT capi directory required}" ort_kind="${2:?provider kind required}"
  local ort_wheels="${3:?wheel directory required}" ort_proof="${4:?proof directory required}"
  local ort_here ort_nullglob=0
  local -a ort_cores=() ort_libraries=()
  _ort_require_gpu_kind "${ort_kind}" 'Python GPU provider' || return 2
  ort_here="$(_ort_packaging_dir)" || return 1
  if shopt -q nullglob; then ort_nullglob=1; fi
  shopt -s nullglob
  ort_cores=("${ort_site}"/libonnxruntime.so.*)
  if [ "${ort_nullglob}" -eq 0 ]; then shopt -u nullglob; fi
  [ "${#ort_cores[@]}" -eq 1 ] || { printf 'expected one Python ORT core, found %s\n' "${#ort_cores[@]}" >&2; return 1; }
  # The CUDA plugin EP is the GPU wheel's; the plugin MIGraphX EP is no wheel's and is proved against the image's module instead.
  ort_libraries=(--library "${ort_cores[0]}")
  [ "${ort_kind}" != cuda ] || ort_libraries+=(--library "${ort_site}/libonnxruntime_providers_shared.so" --library "$(ort_python_provider_file "${ort_site}" cuda)")
  mkdir -p "${ort_proof}" || return 1
  python3 "${ort_here}/stage-ort-wheel-licenses.py" --wheel-dir "${ort_wheels}" "${ort_libraries[@]}" \
    --destination "${ort_proof}" --strip strip --require-unstripped >&2
}

# <file>: a bundled plugin MIGraphX EP is a regular file, byte for byte the image's module, whose media stage already read both plugin entry points (no wheel carries it).
ort_assert_plugin_module() {
  local ort_image; ort_image="$(ort_amdgpu_ep_dir)/${ORT_AMDGPU_EP_MODULE}"
  if [ ! -f "$1" ] || [ -L "$1" ]; then printf 'missing or linked plugin MIGraphX EP: %s\n' "$1" >&2; return 1; fi
  cmp -s "$1" "${ort_image}" && return 0
  printf "%s is not the image's %s\n" "$1" "${ort_image}" >&2
  return 1
}
_ort_validate_python_plugin_module() { ort_assert_plugin_module "$(ort_python_provider_file "$1" migraphx)"; }

_ort_emit_python_host_lines() {
  local ort_label="$1" ort_lines="$2" ort_soname
  while IFS= read -r ort_soname; do
    [ -n "${ort_soname}" ] || continue
    printf '%s\t%s\n' "${ort_label}" "${ort_soname}"
  done <<< "${ort_lines}"
}

# Prove the Python GPU EP (the CUDA plugin against one wheel, the MIGraphX plugin against the image's module) and emit its required host SONAMEs.
ort_python_host_runtime_needed() {
  local ort_site="${1:?ORT capi directory required}" ort_kind="${2:?provider kind required}"
  local ort_wheels="${3:?wheel directory required}" ort_proof="${4:?proof directory required}" ort_selected ort_required
  ort_selected="$(ort_python_provider_file "${ort_site}" "${ort_kind}")" || return 2
  _ort_validate_python_provider_wheel "${ort_site}" "${ort_kind}" "${ort_wheels}" "${ort_proof}" || return 1
  [ "${ort_kind}" != migraphx ] || _ort_validate_python_plugin_module "${ort_site}" || return 1
  ort_required="$(ort_host_runtime_needed "${ort_selected}" "${ort_kind}")" || return 1
  _ort_emit_python_host_lines required "${ort_required}"
}

# <kind> <file>: 0 when the entry is a host SDK library the bundle must not carry; the plugin MIGraphX EP matches the MIGraphX glob by name but is the bundle's own EP.
_ort_host_sdk_file() {
  local ort_name="${2##*/}"
  if [ ! -f "$2" ] && [ ! -L "$2" ]; then return 1; fi
  [ "${ort_name}" != "${ORT_AMDGPU_EP_MODULE}" ] || return 1
  case "$1:${ort_name}" in
    cuda:libcuda.so*|cuda:libcudart.so*|cuda:libcublas*.so*|cuda:libcurand.so*|cuda:libcudnn*.so*|cuda:libcufft*.so*|cuda:libcusparse*.so*|cuda:libnvrtc*.so*|cuda:libnvJitLink*.so*|cuda:libnvidia*.so*|cuda:libnvinfer*.so*|cuda:libnvonnxparser*.so*|migraphx:libmigraphx*.so*|migraphx:libamdhip*.so*|migraphx:libhsa-runtime*.so*|migraphx:libamd_comgr*.so*|migraphx:librocm*.so*|migraphx:librocblas*.so*|migraphx:libhipblas*.so*|migraphx:libMIOpen*.so*)
      return 0 ;;
    *) return 1 ;;
  esac
}

# A host-runtime bundle must not accidentally redistribute GPU SDK libraries.
ort_assert_no_bundled_host_runtime() {
  local ort_tree="${1:?bundle required}" ort_kind="${2:?provider kind required}" ort_file ort_list ort_root ort_bad='' ort_root_ok=0
  case "${ort_kind}" in cuda|migraphx) ;; *) printf 'unknown GPU provider: %s\n' "${ort_kind}" >&2; return 2 ;; esac
  [ -d "${ort_tree}" ] || { printf 'no bundle at %s\n' "${ort_tree}" >&2; return 1; }
  ort_tree="$(realpath -e -- "${ort_tree}")" || { printf 'cannot resolve bundle root\n' >&2; return 1; }
  ort_list="$(mktemp)" || return 1
  if ! find "${ort_tree}" -print0 > "${ort_list}"; then
    rm -f -- "${ort_list}"
    printf 'could not enumerate bundle for host GPU runtime exclusion: %s\n' "${ort_tree}" >&2
    return 1
  fi
  {
    if IFS= read -r -d '' ort_root && [ "${ort_root}" = "${ort_tree}" ]; then
      ort_root_ok=1
      while IFS= read -r -d '' ort_file; do
        if _ort_host_sdk_file "${ort_kind}" "${ort_file}"; then ort_bad="${ort_file}"; break; fi
      done
    fi
  } < "${ort_list}"
  rm -f -- "${ort_list}"
  if [ "${ort_root_ok}" -ne 1 ]; then printf 'bundle enumeration did not return its root: %s\n' "${ort_tree}" >&2; return 1; fi
  if [ -n "${ort_bad}" ]; then printf 'host GPU runtime library was bundled: %s\n' "${ort_bad}" >&2; return 1; fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  stage_ort_runtime "$@"
fi
