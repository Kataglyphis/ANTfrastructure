#!/usr/bin/env bash
# ORT_PYTHON_GPU_HOST_IMPORTS_API=1

# Stage the selected chain ONNX Runtime and provider; the caller verifies provenance and licenses.

stage_ort_runtime() {
  local ort_dest="${1:?destination required}" ort_dir="${2:?ORT directory required}" ort_variant="${3:?variant required}" ort_file
  local -a ort_files=(libonnxruntime.so libonnxruntime.so.1)
  case "${ort_variant}" in
    cpu) ;;
    nvidia) ort_files+=(libonnxruntime_providers_shared.so libonnxruntime_providers_cuda.so) ;;
    amd) ort_files+=(libonnxruntime_providers_shared.so libonnxruntime_providers_migraphx.so) ;;
    *) printf 'unknown ORT variant: %s\n' "${ort_variant}" >&2; return 2 ;;
  esac
  for ort_file in "${ort_files[@]}"; do
    [ -f "${ort_dir}/${ort_file}" ] || { printf 'ORT %s variant requires %s\n' "${ort_variant}" "${ort_dir}/${ort_file}" >&2; return 1; }
  done
  mkdir -p "${ort_dest}" || return
  for ort_file in "${ort_files[@]}"; do cp -L "${ort_dir}/${ort_file}" "${ort_dest}/${ort_file}" || return; done
}

_ort_host_import_class() {
  local ort_kind="$1" ort_soname="$2"
  case "${ort_soname}" in
    *[!A-Za-z0-9._+-]*) return 1 ;;
    libc.so.6|libm.so.6|libstdc++.so.6|libgcc_s.so.1|libpthread.so.0|libdl.so.2|librt.so.1|ld-linux*.so*) printf 'system\n'; return ;;
  esac
  case "${ort_kind}:${ort_soname}" in
    cuda:libcuda.so.*|cuda:libcudart.so.*|cuda:libcublas.so.*|cuda:libcublasLt.so.*|cuda:libcurand.so.*|cuda:libcudnn*.so.*|cuda:libcufft*.so.*|cuda:libcusparse.so.*|cuda:libnvrtc.so.*|cuda:libnvJitLink.so.*) printf 'a\n' ;;
    migraphx:libmigraphx_c.so.*|tensorrt:libnvinfer.so.*) printf 'a\n' ;;
    migraphx:libamdhip64.so.*|tensorrt:libnvonnxparser.so.*) printf 'b\n' ;;
    tensorrt:libcudart.so.*|tensorrt:libcublas.so.*|tensorrt:libcudnn.so.*) printf 'c\n' ;;
    *) return 1 ;;
  esac
}

_ort_host_imports_complete() {
  case "$1:$2:$3:$4" in cuda:1:*:*|migraphx:1:1:*|tensorrt:1:1:1) return 0 ;; *) return 1 ;; esac
}

_ort_packaging_dir() {
  cd "$(dirname "${BASH_SOURCE[0]}")" || return
  pwd
}

# List the exact vendor SONAMEs a provider leaves to the host; unknown direct imports fail closed.
ort_host_runtime_needed() {
  local ort_provider="${1:?provider library required}" ort_kind="${2:?provider kind required}"
  local ort_dyn ort_soname ort_here ort_class ort_seen_a=0 ort_seen_b=0 ort_seen_c=0
  case "${ort_kind}" in cuda|migraphx|tensorrt) ;; *) printf 'unknown GPU provider: %s\n' "${ort_kind}" >&2; return 2 ;; esac
  ort_here="$(_ort_packaging_dir)" || return 1
  # shellcheck source=linux/scripts/06-packaging/elf-needed.sh
  source "${ort_here}/elf-needed.sh" || return 1
  ort_dyn="$(elf_dynamic_needed "${ort_provider}")" || return 1
  while IFS= read -r ort_soname; do
    [ -n "${ort_soname}" ] || continue
    ort_class="$(_ort_host_import_class "${ort_kind}" "${ort_soname}")" || {
      printf 'unexpected or invalid %s provider dependency: %s\n' "${ort_kind}" "${ort_soname}" >&2; return 1;
    }
    case "${ort_class}" in system) continue ;; a) ort_seen_a=1 ;; b) ort_seen_b=1 ;; c) ort_seen_c=1 ;; esac
    printf '%s\n' "${ort_soname}"
  done <<< "${ort_dyn}"
  if ! _ort_host_imports_complete "${ort_kind}" "${ort_seen_a}" "${ort_seen_b}" "${ort_seen_c}"; then
    printf '%s provider does not declare its expected host runtime dependencies\n' "${ort_kind}" >&2
    return 1
  fi
}

_ort_validate_python_provider_wheel() {
  local ort_site="${1:?ORT capi directory required}" ort_kind="${2:?provider kind required}"
  local ort_wheels="${3:?wheel directory required}" ort_proof="${4:?proof directory required}"
  local ort_here ort_selected ort_optional ort_nullglob=0
  local -a ort_cores=() ort_libraries=()
  case "${ort_kind}" in cuda|migraphx) ;; *) printf 'unknown Python GPU provider: %s\n' "${ort_kind}" >&2; return 2 ;; esac
  ort_here="$(_ort_packaging_dir)" || return 1
  if shopt -q nullglob; then ort_nullglob=1; fi
  shopt -s nullglob
  ort_cores=("${ort_site}"/libonnxruntime.so.*)
  if [ "${ort_nullglob}" -eq 0 ]; then shopt -u nullglob; fi
  [ "${#ort_cores[@]}" -eq 1 ] || { printf 'expected one Python ORT core, found %s\n' "${#ort_cores[@]}" >&2; return 1; }
  ort_selected="${ort_site}/libonnxruntime_providers_${ort_kind}.so"
  ort_optional="${ort_site}/libonnxruntime_providers_tensorrt.so"
  ort_libraries=(--library "${ort_cores[0]}" --library "${ort_site}/libonnxruntime_providers_shared.so" --library "${ort_selected}")
  if [ "${ort_kind}" = cuda ] && { [ -e "${ort_optional}" ] || [ -L "${ort_optional}" ]; }; then
    [ -f "${ort_optional}" ] || { printf 'invalid TensorRT provider: %s\n' "${ort_optional}" >&2; return 1; }
    ort_libraries+=(--library "${ort_optional}")
  fi
  mkdir -p "${ort_proof}" || return 1
  python3 "${ort_here}/stage-ort-wheel-licenses.py" --wheel-dir "${ort_wheels}" "${ort_libraries[@]}" \
    --destination "${ort_proof}" --strip strip --require-unstripped >&2
}

_ort_emit_python_host_lines() {
  local ort_label="$1" ort_lines="$2" ort_exclude="${3-}" ort_soname
  while IFS= read -r ort_soname; do
    [ -n "${ort_soname}" ] || continue
    if [ -n "${ort_exclude}" ] && printf '%s\n' "${ort_exclude}" | grep -qxF -- "${ort_soname}"; then continue; fi
    printf '%s\t%s\n' "${ort_label}" "${ort_soname}"
  done <<< "${ort_lines}"
}

_ort_emit_python_host_imports() {
  local ort_kind="$1" ort_required="$2" ort_optional="$3" ort_optional_needed
  _ort_emit_python_host_lines required "${ort_required}"
  if [ "${ort_kind}" = cuda ] && [ -f "${ort_optional}" ]; then
    ort_optional_needed="$(ort_host_runtime_needed "${ort_optional}" tensorrt)" || return 1
    _ort_emit_python_host_lines optional "${ort_optional_needed}" "${ort_required}"
  fi
}

# Prove the Python provider bytes against one wheel and emit required/optional host SONAMEs.
ort_python_host_runtime_needed() {
  local ort_site="${1:?ORT capi directory required}" ort_kind="${2:?provider kind required}"
  local ort_wheels="${3:?wheel directory required}" ort_proof="${4:?proof directory required}"
  local ort_selected="${ort_site}/libonnxruntime_providers_${ort_kind}.so"
  local ort_optional="${ort_site}/libonnxruntime_providers_tensorrt.so" ort_required
  _ort_validate_python_provider_wheel "${ort_site}" "${ort_kind}" "${ort_wheels}" "${ort_proof}" || return 1
  ort_required="$(ort_host_runtime_needed "${ort_selected}" "${ort_kind}")" || return 1
  _ort_emit_python_host_imports "${ort_kind}" "${ort_required}" "${ort_optional}"
}

# A host-runtime bundle must not accidentally redistribute GPU SDK libraries.
ort_assert_no_bundled_host_runtime() {
  local ort_tree="${1:?bundle required}" ort_kind="${2:?provider kind required}" ort_file ort_name ort_list ort_root ort_bad='' ort_root_ok=0
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
        if [ ! -f "${ort_file}" ] && [ ! -L "${ort_file}" ]; then continue; fi
        ort_name="${ort_file##*/}"
        case "${ort_kind}:${ort_name}" in
          cuda:libcuda.so*|cuda:libcudart.so*|cuda:libcublas*.so*|cuda:libcurand.so*|cuda:libcudnn*.so*|cuda:libcufft*.so*|cuda:libcusparse*.so*|cuda:libnvrtc*.so*|cuda:libnvJitLink*.so*|cuda:libnvidia*.so*|cuda:libnvinfer*.so*|cuda:libnvonnxparser*.so*|migraphx:libmigraphx*.so*|migraphx:libamdhip*.so*|migraphx:libhsa-runtime*.so*|migraphx:libamd_comgr*.so*|migraphx:librocm*.so*|migraphx:librocblas*.so*|migraphx:libhipblas*.so*|migraphx:libMIOpen*.so*)
            ort_bad="${ort_file}"
            break ;;
        esac
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
