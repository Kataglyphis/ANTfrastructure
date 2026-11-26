#!/usr/bin/env bash
# Keeps a finished package's ORT libraries and notices inside its root and names the wheel proof's mode; it compares no library itself.

_ort_package_inside() {
  local resolved
  resolved="$(realpath -e "$2")" || return 1
  case "$resolved/" in "$1/"*) return 0 ;; esac
  printf '%s\n' "$3" >&2
  return 1
}

_ort_package_check_library() {
  local root="$1" file="$2" name resolved
  _ort_package_inside "$root" "$file" 'ORT library escapes package' || return 1
  resolved="$(realpath -e "$file")" || return 1
  name="${file##*/}"
  case "$name" in
    libonnxruntime_providers_*)
      [ ! -L "$file" ] || { printf 'ORT provider is a symlink: %s\n' "$name" >&2; return 1; } ;;
    libonnxruntime.so*)
      [[ "${resolved##*/}" =~ ^libonnxruntime\.so(\.[0-9]+)*$ ]] || {
        printf 'ORT core aliases another component: %s\n' "$name" >&2; return 1;
      } ;;
  esac
  return 0
}

_ort_package_refuse_link() {
  [ "$1" = 1 ] || [ ! -L "$2" ] || { printf 'Linked GPU ORT library: %s\n' "$2" >&2; return 1; }
  return 0
}

_ort_package_check_required() {
  local lib="$1" allow_links="$2" name
  shift 2
  for name in "$@"; do
    [ -f "$lib/$name" ] || { printf 'Missing GPU ORT library: %s\n' "$name" >&2; return 1; }
    _ort_package_refuse_link "$allow_links" "$lib/$name" || return 1
  done
  return 0
}

# Usage: ort_package_collect_libraries [--reject-invalid] [--reject-links] ROOT LIB_DIR OUT_ARRAY REQUIRED...
ort_package_collect_libraries() {
  local skip_invalid=1 allow_links=1
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --reject-invalid) skip_invalid=0 ;;
      --reject-links) allow_links=0 ;;
      *) break ;;
    esac
    shift
  done
  local root lib="$2" file
  local -n _ort_package_out="$3"
  root="$(realpath -e "$1")" || return 1
  shift 3
  _ort_package_check_required "$lib" "$allow_links" "$@" || return 1
  for file in "$lib"/libonnxruntime*.so*; do
    if [ ! -f "$file" ]; then
      [ "$skip_invalid" = 1 ] && continue
      printf 'Invalid ORT library: %s\n' "$file" >&2
      return 1
    fi
    _ort_package_refuse_link "$allow_links" "$file" || return 1
    _ort_package_check_library "$root" "$file" || return 1
    _ort_package_out+=(--library "$file")
  done
  return 0
}

# Usage: ort_package_verify_notices ROOT NOTICE_DIR PROOF_DIR
ort_package_verify_notices() {
  local root notice_dir="$2" proof_dir="$3" name notice
  root="$(realpath -e "$1")" || return 1
  for name in LICENSE ThirdPartyNotices.txt; do
    notice="$notice_dir/$name"
    [ -f "$notice" ] && [ ! -L "$notice" ] || { printf 'Missing or linked ORT notice: %s\n' "$notice" >&2; return 1; }
    _ort_package_inside "$root" "$notice" 'ORT notice escapes package' || return 1
    cmp "$notice" "$proof_dir/$name" || return 1
  done
  return 0
}

_ort_package_amdgpu_license_source() {
  local image_licenses
  image_licenses="$(ort_amdgpu_ep_dir)/../licenses"
  [ -s "$image_licenses/onnxruntime-ep-amdgpu/LICENSE" ] || {
    printf 'Image plugin license tree is missing\n' >&2; return 1;
  }
  printf '%s\n' "$image_licenses"
}

_ort_package_amdgpu_provenance() {
  local operation="$1" root="$2" licenses="$3" destination="$4" source parent resolved license_root
  source="$(ort_amdgpu_ep_dir)/../provenance.txt"
  [ -s "$source" ] && [ ! -L "$source" ] || {
    printf 'Image plugin provenance is missing, empty or linked\n' >&2; return 1;
  }
  parent="$(realpath -e "$(dirname "$destination")")" || return 1
  _ort_package_inside "$root" "$parent" 'Plugin provenance destination escapes package' || return 1
  resolved="$(realpath -m "$destination")" || return 1
  license_root="$(realpath -m "$licenses")" || return 1
  case "$resolved/" in "$license_root/"*)
    printf 'Plugin provenance must stay outside the exact license tree\n' >&2; return 1 ;;
  esac
  if [ "$operation" = stage ]; then
    [ ! -e "$destination" ] && [ ! -L "$destination" ] || {
      printf 'Plugin provenance destination already exists\n' >&2; return 1;
    }
    cp "$source" "$destination" || return
  fi
  [ -f "$destination" ] && [ ! -L "$destination" ] || {
    printf 'Packaged plugin provenance is missing or linked\n' >&2; return 1;
  }
  cmp "$source" "$destination"
}

_ort_package_amdgpu() {
  local operation="$1" root lib="$3" licenses="$4" image_licenses
  root="$(realpath -e "$2")" || return 1
  _ort_package_inside "$root" "$lib/${ORT_AMDGPU_EP_MODULE}" 'Plugin module escapes package' || return 1
  ort_assert_plugin_module "$lib/${ORT_AMDGPU_EP_MODULE}" || return 1
  if [ -e "$lib/libonnxruntime_providers_migraphx.so" ] || [ -L "$lib/libonnxruntime_providers_migraphx.so" ]; then
    printf 'Legacy built-in MIGraphX provider is not allowed in a plugin package\n' >&2
    return 1
  fi
  image_licenses="$(_ort_package_amdgpu_license_source)" || return 1
  if [ -n "${5:-}" ]; then
    _ort_package_amdgpu_provenance "$operation" "$root" "$licenses" "$5" || return
  fi
  if [ "$operation" = stage ]; then
    _ort_package_inside "$root" "$(dirname "$licenses")" 'Plugin license destination escapes package' || return 1
    mkdir "$licenses" || return
    cp -a "$image_licenses/." "$licenses/" || return
  fi
  _ort_package_inside "$root" "$licenses" 'Plugin licenses escape package' || return 1
  diff --no-dereference -qr "$image_licenses" "$licenses"
}

# Optional PROVENANCE_FILE binds the original image text separately from the exact license tree; this proves no inference.
ort_package_verify_amdgpu() { _ort_package_amdgpu verify "$@"; }

# Usage: ort_package_stage_amdgpu_licenses ROOT LIB_DIR NEW_LICENSE_DIR [NEW_PROVENANCE_FILE]; parents must exist inside ROOT.
ort_package_stage_amdgpu_licenses() { _ort_package_amdgpu stage "$@"; }

# Usage: ort_package_require_program ROOT FILE; path, mode and regular-file checks, not execution or byte identity.
ort_package_require_program() {
  if [ ! -f "$2" ] || [ -L "$2" ] || [ ! -x "$2" ]; then
    printf 'Missing, linked or nonexecutable packaged program: %s\n' "$2" >&2
    return 1
  fi
  _ort_package_inside "$1" "$2" 'Packaged program escapes package'
}

# ort_wheel_proof_args KIND: stage-ort-wheel-licenses.py's proof options; the AMD image strips its CPU core with its own strip, NVIDIA's prefix ships unstripped.
ort_wheel_proof_args() {
  case "$1" in
    migraphx) printf '%s\n' --strip strip ;;
    *) printf '%s\n' --require-unstripped --strip "${STRIP:-strip}" ;;
  esac
}
