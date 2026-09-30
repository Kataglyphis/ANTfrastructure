#!/usr/bin/env bash
# Sourced core, so it sets no shell options. docs/code-quality-tooling.md#linuxscriptslibcode-qualitysh--the-shared-library

[ -n "${_CODE_QUALITY_SH_LOADED:-}" ] && return 0
_CODE_QUALITY_SH_LOADED=1

# shellcheck source=./log-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/log-bootstrap.sh"

# Declares has_tool/require_tools only when the caller has not, so a project's own win.
# shellcheck source=../01-core/tool-checks.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../01-core/tool-checks.sh"

_code_quality_project_root() {
  printf '%s\n' "${CODE_QUALITY_PROJECT_ROOT:-$(pwd)}"
}

# cmake-format availability; paths resolve from this file, so a vendored checkout works too.
_CQ_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_CQ_CORE="${_CQ_LIB_DIR}/../01-core"
_CQ_REQS="${_CQ_LIB_DIR}/../cmake-format.requirements.txt"

_code_quality_default_venv_create() {
  # shellcheck source=../01-core/python_uv.sh
  source "${_CQ_CORE}/python_uv.sh"
  # No --python pin: the CI image's UV_PYTHON decides, and a pin fails there.
  uv_venv_create "${venv_dir}" ""
}

_code_quality_default_install_requirements() {
  # shellcheck source=../01-core/python_uv.sh
  source "${_CQ_CORE}/python_uv.sh"
  uv_pip_install_requirements "${venv_dir}" "${_CQ_REQS}"
}

_code_quality_apply_default_bootstrap() {
  [[ -f "${_CQ_REQS}" ]] || err "cmake-format not found and the hub's ${_CQ_REQS} is missing -- this is a broken checkout, not a gate to skip."
  [[ -n "${create_script}" ]] || create_script=_code_quality_default_venv_create
  [[ -n "${install_script}" ]] || install_script=_code_quality_default_install_requirements
}

code_quality_ensure_cmake_format() {
  if has_tool cmake-format; then
    return 0
  fi

  local root venv_dir create_script install_script
  root="$(_code_quality_project_root)"
  venv_dir="${CODE_QUALITY_VENV_DIR:-${root}/.venv}"
  create_script="${CODE_QUALITY_UV_VENV_CREATE_SCRIPT:-}"
  install_script="${CODE_QUALITY_UV_INSTALL_REQUIREMENTS_SCRIPT:-}"

  # Unset knobs mean the hub's venv and pinned requirements, not a refusal.
  _code_quality_apply_default_bootstrap

  if ! has_tool uv; then
    err "Required tool not found: uv (needed to manage ${venv_dir} and install requirements)"
  fi

  info "cmake-format not found. Preparing Python environment..."

  # A venv from the other platform dies in uv with "Exec format error"; probe and recreate.
  if [[ -d "${venv_dir}" ]]; then
    local venv_python="${venv_dir}/bin/python"
    [[ -x "${venv_python}" ]] || venv_python="${venv_dir}/Scripts/python.exe"
    if [[ -x "${venv_python}" ]] && "${venv_python}" -c 'pass' >/dev/null 2>&1; then
      info "Found .venv - installing requirements..."
    else
      info "Found .venv but its interpreter does not run here (foreign platform or broken) - recreating..."
      rm -rf "${venv_dir}"
      (cd "${root}" && "${create_script}")
    fi
  else
    info "No .venv found - creating one with uv..."
    (cd "${root}" && "${create_script}")
  fi
  (cd "${root}" && "${install_script}")

  # A Windows-created venv has Scripts/; neither existing is a broken venv, failed by name.
  local activate="${venv_dir}/bin/activate"
  [[ -f "${activate}" ]] || activate="${venv_dir}/Scripts/activate"
  if [[ ! -f "${activate}" ]]; then
    err "No activate script in ${venv_dir} (neither bin/activate nor Scripts/activate exists)."
  fi
  # shellcheck disable=SC1090
  source "${activate}"

  if ! has_tool cmake-format; then
    err "cmake-format is still not available after installing requirements."
  fi
}

# File enumeration
_code_quality_name_predicate() {
  _CODE_QUALITY_NAME_PREDICATE=('(')
  local first=1 ext
  for ext in "$@"; do
    [[ ${first} -eq 1 ]] || _CODE_QUALITY_NAME_PREDICATE+=(-o)
    _CODE_QUALITY_NAME_PREDICATE+=(-name "*.${ext}")
    first=0
  done
  _CODE_QUALITY_NAME_PREDICATE+=(')')
}

# Hub helpers create these in consumer trees; a consumer's list adds to them. docs/shared-script-libraries.md#05-frameworksflutterlane-prologuesh
CODE_QUALITY_CMAKE_DEFAULT_EXCLUDES=(
  '*/.pub-cache/*'
)

# Paths stay relative to the search root, as cmake-format wants them.
code_quality_find_cmake_files() {
  local root="${CODE_QUALITY_CMAKE_SEARCH_ROOT:-.}"
  local find_args=("${root}" -type f '(' -name 'CMakeLists.txt' -o -name '*.cmake' ')')

  local excl
  for excl in "${CODE_QUALITY_CMAKE_DEFAULT_EXCLUDES[@]}" \
              "${CODE_QUALITY_CMAKE_EXCLUDE_PATHS[@]:-}"; do
    [[ -n "${excl}" ]] || continue
    find_args+=(-not -path "${excl}")
  done

  find "${find_args[@]}"
}

# Extensions come from CODE_QUALITY_CPP_FORMAT_EXTENSIONS.
code_quality_find_cpp_files() {
  [[ $# -gt 0 ]] || return 0

  local exts=("${CODE_QUALITY_CPP_FORMAT_EXTENSIONS[@]:-}")
  if [[ -z "${exts[0]:-}" ]]; then
    exts=(c cc cpp cxx h hh hpp hxx ixx cppm ccm cxxm mpp)
  fi

  _code_quality_name_predicate "${exts[@]}"
  find "$@" -type f "${_CODE_QUALITY_NAME_PREDICATE[@]}"
}

# Headers are excluded: clang-tidy needs a compile-DB entry.
code_quality_find_clang_tidy_files() {
  [[ $# -gt 0 ]] || return 0

  local exts=("${CODE_QUALITY_CLANG_TIDY_EXTENSIONS[@]:-}")
  if [[ -z "${exts[0]:-}" ]]; then
    exts=(c cc cpp cxx)
  fi

  _code_quality_name_predicate "${exts[@]}"
  find "$@" -type f "${_CODE_QUALITY_NAME_PREDICATE[@]}"
}

# Tracked files, not `dart format .`: CI installs Flutter inside the workspace, and the walk would reformat it.
code_quality_find_dart_files() {
  code_quality_find_tracked_files "${1:-.}" '*.dart'
}

# The one owner of the never-graded trees; a caller that restates the list drifts from the other gates.
code_quality_find_tracked_files() {
  local root="${1:-.}"
  shift
  command -v git >/dev/null 2>&1 || return 0

  local f
  git -C "$root" ls-files -- "$@" 2>/dev/null | while IFS= read -r f; do
    case "$f" in
      build/*|*/build/*|ExternalLib/*|*/ExternalLib/*|third_party/*|*/third_party/*) continue ;;
      flutter/*|*/flutter/*|rust_builder/*|*/rust_builder/*) continue ;;
    esac
    if [ "$root" = "." ]; then printf '%s\n' "$f"; else printf '%s/%s\n' "$root" "$f"; fi
  done
}

# Formatting steps. A leading --check reports drift (non-zero, offenders on stderr) without writing.
code_quality_run_cmake_format() {
  local mode=(-i)
  if [[ "${1:-}" == "--check" ]]; then
    mode=(--check)
    shift
  fi
  [[ $# -gt 0 ]] || return 0

  local config="${CODE_QUALITY_CMAKE_FORMAT_CONFIG-.cmake-format.yaml}"
  local args=()
  if [[ -n "${config}" && -f "${config}" ]]; then
    args+=(-c "${config}")
  fi
  args+=("${mode[@]}")

  cmake-format "${args[@]}" "$@"
}

# One invocation, unlike Windows. docs/code-quality-tooling.md#known-divergences-from-the-windows-path--read-before-unifying-the-two
code_quality_run_clang_format() {
  [[ $# -gt 0 ]] || return 0

  info "Running clang-format on $# files..."
  clang-format -i "$@"
}

# Always returns 0; gate on CODE_QUALITY_CLANG_FORMAT_DEVIATIONS, which this sets.
code_quality_check_clang_format() {
  CODE_QUALITY_CLANG_FORMAT_DEVIATIONS=0
  [[ $# -gt 0 ]] || return 0

  local total=$# file
  local deviating=()
  for file in "$@"; do
    if ! clang-format --dry-run -Werror "${file}" >/dev/null 2>&1; then
      deviating+=("${file}")
    fi
  done

  CODE_QUALITY_CLANG_FORMAT_DEVIATIONS=${#deviating[@]}
  info "clang-format: ${#deviating[@]} of ${total} files deviate from .clang-format."

  local shown=0
  for file in "${deviating[@]}"; do
    [[ ${shown} -lt 20 ]] || break
    info "  deviates: ${file}"
    shown=$((shown + 1))
  done
  if [[ ${#deviating[@]} -gt 20 ]]; then
    info "  ... and $(( ${#deviating[@]} - 20 )) more"
  fi

  return 0
}

# Compile DB: sets CODE_QUALITY_COMPILE_DB_DIR (pair with code_quality_cleanup_compile_db); never regenerates one.
code_quality_prepare_compile_db() {
  local build_dir="$1"
  local compile_db_path="${build_dir}/compile_commands.json"

  CODE_QUALITY_COMPILE_DB_DIR="${build_dir}"
  CODE_QUALITY_COMPILE_DB_TEMP_DIR=""

  if [[ ! -f "${compile_db_path}" ]]; then
    err "Missing ${compile_db_path}. Run CMake configure first.${CODE_QUALITY_COMPILE_DB_HINT:+ ${CODE_QUALITY_COMPILE_DB_HINT}}"
    return 1
  fi

  local workspace="${CODE_QUALITY_CONTAINER_WORKSPACE-/workspace}"
  [[ -n "${workspace}" ]] || return 0

  local root
  root="$(_code_quality_project_root)"

  local toolchain_prefix="${CODE_QUALITY_GCC_TOOLCHAIN_PREFIX-/opt/gcc-}"
  local toolchain_probe="${CODE_QUALITY_GCC_TOOLCHAIN_PROBE_DIR:-}"

  # If the compile DB was generated in a container (/workspace), remap paths for local runs.
  if grep -qF "${workspace}" "${compile_db_path}"; then
    CODE_QUALITY_COMPILE_DB_TEMP_DIR="$(mktemp -d)"
    info "Remapping container paths in compile_commands.json..."
    sed "s#\"${workspace}#\"${root}#g" "${compile_db_path}" > "${CODE_QUALITY_COMPILE_DB_TEMP_DIR}/compile_commands.json"

    # Drop container-only GCC toolchain flags if that toolchain path is unavailable locally.
    if [[ -n "${toolchain_probe}" && -n "${toolchain_prefix}" && ! -d "${toolchain_probe}" ]]; then
      sed -E -i \
        -e "s#[[:space:]]--gcc-toolchain=${toolchain_prefix}[^[:space:]\"]+##g" \
        -e "s#-Wl,-rpath,${toolchain_prefix}[^[:space:]\"]+/lib64##g" \
        -e "s#[[:space:]]-L${toolchain_prefix}[^[:space:]\"]+/lib64##g" \
        "${CODE_QUALITY_COMPILE_DB_TEMP_DIR}/compile_commands.json"
    fi

    CODE_QUALITY_COMPILE_DB_DIR="${CODE_QUALITY_COMPILE_DB_TEMP_DIR}"
  fi

  return 0
}

# Removes the temporary remapped compile DB, if one was created.
code_quality_cleanup_compile_db() {
  if [[ -n "${CODE_QUALITY_COMPILE_DB_TEMP_DIR:-}" ]]; then
    rm -rf "${CODE_QUALITY_COMPILE_DB_TEMP_DIR}"
    CODE_QUALITY_COMPILE_DB_TEMP_DIR=""
  fi
}

# clang-tidy: <compile-db-dir> <file>...; one invocation, flags from CODE_QUALITY_CLANG_TIDY_ARGS/_FIX.
code_quality_run_clang_tidy() {
  local db_dir="$1"
  shift
  [[ $# -gt 0 ]] || return 0

  local args=(-p "${db_dir}")
  local extra
  for extra in "${CODE_QUALITY_CLANG_TIDY_ARGS[@]:-}"; do
    [[ -n "${extra}" ]] || continue
    args+=("${extra}")
  done
  if [[ "${CODE_QUALITY_CLANG_TIDY_FIX:-false}" == "true" ]]; then
    args+=(-fix)
  fi

  info "Running clang-tidy on $# files..."
  clang-tidy "${args[@]}" "$@"
}
