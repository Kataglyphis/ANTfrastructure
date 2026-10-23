# Python cross-compilation helpers, sourced by cross-env.sh.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "This script is meant to be sourced, not executed" >&2
  exit 1
fi

[ -z "${_CROSS_PYTHON_LOADED:-}" ] || return 0
_CROSS_PYTHON_LOADED=1

# Prints its first argument if it is an executable path, else fails; an unset pin is an empty argument.
_host_python_try() {
  [ -n "$1" ] && [ -x "$1" ] || return 1
  printf '%s' "$1"
}

host_python_bin() {
  local interpreter
  interpreter="$(_resolve_first_path -x \
    "${MEDIA_HOST_PYTHON:-}" \
    "${UV_PYTHON:-}" \
    "${VIRTUAL_ENV:+${VIRTUAL_ENV}/bin/python}" \
    "${PYTHON_MAJOR_MINOR:+/usr/local/bin/python${PYTHON_MAJOR_MINOR}}")" && {
    printf '%s' "${interpreter}"
    return 0
  }

  if [ -n "${PYTHON_VERSION:-}" ] && command -v version_major_minor >/dev/null 2>&1; then
    local python_mm=""
    python_mm="$(version_major_minor "${PYTHON_VERSION}" 2>/dev/null || true)"
    _host_python_try "${python_mm:+/usr/local/bin/python${python_mm}}" && return 0
  fi
  command -v python3 2>/dev/null || command -v python 2>/dev/null || return 1
}

host_python_major_minor() {
  local python_bin

  if [ -n "${PYTHON_MAJOR_MINOR:-}" ]; then
    printf '%s' "${PYTHON_MAJOR_MINOR}"
    return 0
  fi

  python_bin="$(host_python_bin)" || return 1
  "${python_bin}" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")'
}

cross_target_python_stage_root() {
  local target_arch=""

  target_arch="$(cross_require_single_target_arch "$(default_target_arch "${1:-}")" "target Python staging")" || return 1
  printf '%s' "${PYTHON_CROSS_STAGE_ROOT:-/opt/python-cross}/${target_arch}"
}

cross_target_python_active_stage_root() {
  local requested_arch
  requested_arch="$(default_target_arch "${1:-}")"
  local active_root="${PYTHON_CROSS_ACTIVE_ROOT:-/opt/python-target}"
  local stage_root=""

  if [ -d "${active_root}/usr/local" ]; then
    printf '%s' "${active_root}"
    return 0
  fi

  stage_root="$(cross_target_python_stage_root "${requested_arch}" 2>/dev/null || true)"
  if [ -n "${stage_root}" ] && [ -d "${stage_root}/usr/local" ]; then
    printf '%s' "${stage_root}"
    return 0
  fi

  return 1
}

cross_target_python_root() {
  local active_root=""

  active_root="$(cross_target_python_active_stage_root "$@" 2>/dev/null || true)"
  if [ -n "${active_root}" ] && [ -d "${active_root}/usr/local" ]; then
    printf '%s' "${active_root}/usr/local"
    return 0
  fi

  return 1
}

# <triplet> <root>: the dir under <root>/lib holding _sysconfigdata__linux_<triplet>.py, or rc 1.
cross_target_sysconfigdata_dir() {
  local triplet="${1:-}" root="${2:-}" dir=""
  [ -n "${triplet}" ] && [ -n "${root}" ] && [ -d "${root}/lib" ] || return 1
  # -maxdepth 4: a staged interpreter keeps it in lib/python3.X/ or its lib-dynload/.
  dir="$(find "${root}/lib" -maxdepth 4 -name "_sysconfigdata__linux_${triplet}.py" -printf '%h\n' -quit 2>/dev/null || true)"
  [ -n "${dir}" ] || return 1
  printf '%s' "${dir}"
}

cross_target_python_major_minor() {
  if [ -n "${TARGET_PYTHON_MAJOR_MINOR:-}" ]; then
    printf '%s' "${TARGET_PYTHON_MAJOR_MINOR}"
    return 0
  fi

  host_python_major_minor
}

# _resolve_first_path <-d|-f> <path>...: prints the first that passes the test.
_resolve_first_path() {
  local test_flag="${1:--d}"
  shift
  local candidate
  for candidate in "$@"; do
    [ -n "${candidate}" ] || continue
    # The linter cannot parse a dynamic test operator; it is valid at runtime.
    # shellcheck disable=SC1072,SC1073
    [ "${test_flag}" "${candidate}" ] && { printf '%s' "${candidate}"; return 0; }
  done
  return 1
}

cross_target_python_include_dir() {
  local python_mm python_root
  python_mm="$(cross_target_python_major_minor)" || return 1
  python_root="$(cross_target_python_root "$@" 2>/dev/null || true)"
  _resolve_first_path -d \
    "${python_root:+${python_root}/include/python${python_mm}}" \
    "/usr/local/include/python${python_mm}" \
    "/usr/include/python${python_mm}"
}

# The caller owns these locals so nested path probes cannot overwrite its parent scope.
_cross_target_python_build_context() {
  python_mm="$(cross_target_python_major_minor)" || return 1
  triplet="$(cross_target_triplet 2>/dev/null || true)"
  python_root="$(cross_target_python_root "$@" 2>/dev/null || true)"
}

cross_target_python_arch_include_dir() {
  local python_mm triplet python_root
  _cross_target_python_build_context "$@" || return 1
  _resolve_first_path -d \
    "${python_root:+${python_root}/include/${triplet}/python${python_mm}}" \
    "${python_root:+${python_root}/include/python${python_mm}}" \
    "/usr/local/include/${triplet}/python${python_mm}" \
    "/usr/include/${triplet}/python${python_mm}" \
    "/usr/local/include/python${python_mm}" \
    "/usr/include/python${python_mm}"
}

_cross_target_python_lib_subdir() {
  local suffix="$1"
  shift
  local triplet python_root
  python_root="$(cross_target_python_root "$@" 2>/dev/null || true)"
  triplet="$(cross_target_triplet 2>/dev/null || true)"
  _resolve_first_path -d \
    "${python_root:+${python_root}/lib${suffix}}" \
    "/usr/local/lib${suffix}" \
    "/usr/lib/${triplet}${suffix}" \
    "/usr/lib${suffix}"
}

cross_target_python_libdir() { _cross_target_python_lib_subdir '' "$@"; }

cross_target_python_library() {
  local python_mm triplet python_root
  _cross_target_python_build_context "$@" || return 1
  _resolve_first_path -f \
    "${python_root:+${python_root}/lib/libpython${python_mm}.so}" \
    "${python_root:+${python_root}/lib/libpython${python_mm}.so.1.0}" \
    "/usr/local/lib/libpython${python_mm}.so" \
    "/usr/local/lib/libpython${python_mm}.so.1.0" \
    "/usr/lib/${triplet}/libpython${python_mm}.so" \
    "/usr/lib/${triplet}/libpython${python_mm}.so.1.0" \
    "/usr/lib/libpython${python_mm}.so" \
    "/usr/lib/libpython${python_mm}.so.1.0"
}

cross_target_python_pkgconfig_dir() { _cross_target_python_lib_subdir /pkgconfig "$@"; }

_cross_target_python_pc_path() {
  local suffix="$1" python_mm pkgconfig_dir
  python_mm="$(cross_target_python_major_minor)" || return 1
  pkgconfig_dir="$(cross_target_python_pkgconfig_dir)" || return 1
  printf '%s' "${pkgconfig_dir}/python-${python_mm}${suffix}.pc"
}

cross_target_python_pc() { _cross_target_python_pc_path ''; }
cross_target_python_embed_pc() { _cross_target_python_pc_path -embed; }

cross_target_python_dev_ready() {
  local include_dir
  local arch_include_dir
  local pc_file
  local embed_pc_file

  include_dir="$(cross_target_python_include_dir)" || return 1
  arch_include_dir="$(cross_target_python_arch_include_dir)" || return 1
  pc_file="$(cross_target_python_pc)" || return 1
  embed_pc_file="$(cross_target_python_embed_pc)" || return 1

  [ -d "${include_dir}" ] || return 1
  [ -d "${arch_include_dir}" ] || return 1
  [ -f "${pc_file}" ] || return 1
  [ -f "${embed_pc_file}" ] || return 1
  cross_target_python_library >/dev/null
}

cross_collect_python_dev_paths() {
  local -n python_paths="$1"
  shift
  local field probe
  for field in "$@"; do
    probe="cross_target_python_${field}"
    if command -v "${probe}" >/dev/null 2>&1; then
      python_paths["${field}"]="$("${probe}" 2>/dev/null || true)"
    fi
  done
}
