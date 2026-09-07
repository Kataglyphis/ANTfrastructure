#!/usr/bin/env bash
# code-quality.sh - generic "format and statically analyse a C/C++ tree" core.
#
# Wrappers set the CODE_QUALITY_* variables, source this file, then call the step
# functions. Variables, and the seven known Linux/Windows divergences, are in
# docs/code-quality-tooling.md § linux/scripts/lib/code-quality.sh.
#
# Sets no -e/-u/-o pipefail: sourcing must not change the caller's shell options.

[ -n "${_CODE_QUALITY_SH_LOADED:-}" ] && return 0
_CODE_QUALITY_SH_LOADED=1

# shellcheck source=./log-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/log-bootstrap.sh"

# has_tool/require_tools normally come from the project's common.sh; define
# equivalents only when the caller has not.
if ! declare -F has_tool >/dev/null 2>&1; then
  has_tool() { command -v "$1" >/dev/null 2>&1; }
fi
if ! declare -F require_tools >/dev/null 2>&1; then
  require_tools() {
    local missing=() tool
    for tool in "$@"; do
      command -v "${tool}" >/dev/null 2>&1 || missing+=("${tool}")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
      err "Required tools not found: ${missing[*]}"
    fi
  }
fi

_code_quality_project_root() {
  printf '%s\n' "${CODE_QUALITY_PROJECT_ROOT:-$(pwd)}"
}

# ---------------------------------------------------------------------------
# cmake-format availability
# ---------------------------------------------------------------------------
# cmake-format ships as a Python package, so a machine without it needs a
# virtualenv first. Venv creation and requirements install are delegated to the
# caller-supplied scripts (which in turn defer to 01-core/python_uv.sh) instead
# of a hand-rolled uv variant; they operate on the caller's cwd, hence the
# subshell cd.
code_quality_ensure_cmake_format() {
  if has_tool cmake-format; then
    return 0
  fi

  local root venv_dir create_script install_script
  root="$(_code_quality_project_root)"
  venv_dir="${CODE_QUALITY_VENV_DIR:-${root}/.venv}"
  create_script="${CODE_QUALITY_UV_VENV_CREATE_SCRIPT:-}"
  install_script="${CODE_QUALITY_UV_INSTALL_REQUIREMENTS_SCRIPT:-}"

  if [[ -z "${create_script}" || -z "${install_script}" ]]; then
    err "cmake-format not found and no venv bootstrap scripts configured (set CODE_QUALITY_UV_VENV_CREATE_SCRIPT and CODE_QUALITY_UV_INSTALL_REQUIREMENTS_SCRIPT)."
  fi

  if ! has_tool uv; then
    err "Required tool not found: uv (needed to manage ${venv_dir} and install requirements)"
  fi

  info "cmake-format not found. Preparing Python environment..."

  if [[ -d "${venv_dir}" ]]; then
    info "Found .venv - installing requirements..."
  else
    info "No .venv found - creating one with uv..."
    (cd "${root}" && "${create_script}")
  fi
  (cd "${root}" && "${install_script}")

  # bin/ is the POSIX venv layout; a venv created on Windows (Git Bash) has
  # Scripts/ instead. Neither existing is a broken venv and must fail by name.
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

# ---------------------------------------------------------------------------
# File enumeration
# ---------------------------------------------------------------------------
# Fills the global array _CODE_QUALITY_NAME_PREDICATE with the
# `( -name '*.ext' -o -name '*.ext2' ... )` fragment of a find command.
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

# Prints, one per line, every CMakeLists.txt / *.cmake under
# CODE_QUALITY_CMAKE_SEARCH_ROOT that no CODE_QUALITY_CMAKE_EXCLUDE_PATHS glob
# matches. Paths stay relative to the search root, as cmake-format wants them.
code_quality_find_cmake_files() {
  local root="${CODE_QUALITY_CMAKE_SEARCH_ROOT:-.}"
  local find_args=("${root}" -type f '(' -name 'CMakeLists.txt' -o -name '*.cmake' ')')

  local excl
  for excl in "${CODE_QUALITY_CMAKE_EXCLUDE_PATHS[@]:-}"; do
    [[ -n "${excl}" ]] || continue
    find_args+=(-not -path "${excl}")
  done

  find "${find_args[@]}"
}

# Prints, one per line, every clang-format-able source under the given
# directories (extensions from CODE_QUALITY_CPP_FORMAT_EXTENSIONS).
code_quality_find_cpp_files() {
  [[ $# -gt 0 ]] || return 0

  local exts=("${CODE_QUALITY_CPP_FORMAT_EXTENSIONS[@]:-}")
  if [[ -z "${exts[0]:-}" ]]; then
    exts=(c cc cpp cxx h hh hpp hxx ixx cppm ccm cxxm mpp)
  fi

  _code_quality_name_predicate "${exts[@]}"
  find "$@" -type f "${_CODE_QUALITY_NAME_PREDICATE[@]}"
}

# Prints, one per line, every translation unit clang-tidy should analyse under
# the given directories (extensions from CODE_QUALITY_CLANG_TIDY_EXTENSIONS).
# Headers are deliberately excluded: clang-tidy needs a compile-DB entry.
code_quality_find_clang_tidy_files() {
  [[ $# -gt 0 ]] || return 0

  local exts=("${CODE_QUALITY_CLANG_TIDY_EXTENSIONS[@]:-}")
  if [[ -z "${exts[0]:-}" ]]; then
    exts=(c cc cpp cxx)
  fi

  _code_quality_name_predicate "${exts[@]}"
  find "$@" -type f "${_CODE_QUALITY_NAME_PREDICATE[@]}"
}

# Prints, one per line, every tracked *.dart file under the given root (default
# "."). The Windows twin is Get-ProjectDartFiles in
# windows/scripts/modules/WindowsFormatting.Common.psm1.
#
# `dart format .` is not an equivalent: the Linux CI lanes install the Flutter
# SDK *inside* the mounted workspace (flutter_dir: /workspace/flutter), so a
# recursive walk reformats the SDK. Measured 2026-09-03 on Kataglyphis-Inference-
# Engine: "Formatted 7404 files (627 changed)", 604 of them under flutter/ —
# enough to fail --set-exit-if-changed on its own. Listing tracked files instead
# also skips vendored submodules and build trees. Docs: docs/code-quality-tooling.md.
code_quality_find_dart_files() {
  local root="${1:-.}"
  command -v git >/dev/null 2>&1 || return 0

  local f
  git -C "$root" ls-files -- '*.dart' 2>/dev/null | while IFS= read -r f; do
    case "$f" in
      build/*|*/build/*|ExternalLib/*|*/ExternalLib/*|third_party/*|*/third_party/*) continue ;;
      flutter/*|*/flutter/*|rust_builder/*|*/rust_builder/*) continue ;;
    esac
    if [ "$root" = "." ]; then printf '%s\n' "$f"; else printf '%s/%s\n' "$root" "$f"; fi
  done
}

# ---------------------------------------------------------------------------
# Formatting steps
# ---------------------------------------------------------------------------
# Rewrites the given CMake files in place. A leading `--check` argument instead
# reports drift without writing: non-zero exit, each offender named on stderr.
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

# Rewrites the given C/C++ sources in place (clang-format -i), in ONE
# invocation - see divergence 5 above.
code_quality_run_clang_format() {
  [[ $# -gt 0 ]] || return 0

  info "Running clang-format on $# files..."
  clang-format -i "$@"
}

# Reports how many of the given sources deviate from .clang-format WITHOUT
# rewriting them, using --dry-run -Werror (non-zero exit per deviating file is
# the signal, not an error). Always returns 0: callers that want a gate should
# test CODE_QUALITY_CLANG_FORMAT_DEVIATIONS, which this sets.
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

# ---------------------------------------------------------------------------
# Compile database preparation
# ---------------------------------------------------------------------------
# Takes the build directory, and sets CODE_QUALITY_COMPILE_DB_DIR to the
# directory that should be passed to `clang-tidy -p`. That is normally the build
# directory itself; when the DB was produced inside a container it is a
# temporary copy with the paths rewritten. Pair every call with
# code_quality_cleanup_compile_db.
#
# Returns non-zero (after err, which exits in the default logging) when the DB
# does not exist - see divergence 6 above: the Linux path deliberately does NOT
# regenerate it from ninja.
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

# ---------------------------------------------------------------------------
# clang-tidy
# ---------------------------------------------------------------------------
# Usage: code_quality_run_clang_tidy <compile-db-dir> <file>...
# Extra arguments come from CODE_QUALITY_CLANG_TIDY_ARGS; -fix is appended when
# CODE_QUALITY_CLANG_TIDY_FIX is "true". One invocation for the whole file list
# - see divergence 5 above.
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
