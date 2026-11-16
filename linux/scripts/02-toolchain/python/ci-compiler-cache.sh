#!/usr/bin/env bash
# Build-only compiler prefixes must not leak into packaging-time runtime discovery.
_PYTHON_CI_CACHE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 1
source "${_PYTHON_CI_CACHE_DIR}/ci-common.sh" || { echo 'Error: failed to source ci-common.sh' >&2; return 1; }
_PYTHON_CI_CACHE_CORE="${_PYTHON_CI_CACHE_DIR}/../../01-core"

python_ci_cache_prepare() {
  [[ -n ${CC:-} && -n ${CXX:-} ]] || { printf 'Cached Python builds require explicit CC and CXX executables\n' >&2; return 2; }
  type -P -- "$CC" >/dev/null && type -P -- "$CXX" >/dev/null || {
    printf 'Cached Python builds require single compiler executables\n' >&2; return 2;
  }
  if ! declare -F compiler_cache_launcher_env >/dev/null || ! declare -F compiler_cache_launcher >/dev/null; then
    # shellcheck source=linux/scripts/01-core/common.sh
    source "${_PYTHON_CI_CACHE_CORE}/common.sh" || return $?
  fi
  declare -F compiler_cache_launcher_env >/dev/null && declare -F compiler_cache_launcher >/dev/null || {
    printf 'Cached Python builds require the core compiler-cache APIs\n' >&2; return 1;
  }
  return 0
}

python_ci_cached_command() {
  [[ $# -gt 0 ]] || { printf 'Expected a Python build command\n' >&2; return 2; }
  case "${PYTHON_BUILD_COMPILER_CACHE:-off}" in
    off) "$@"; return ;;
    on) ;;
    *) printf 'PYTHON_BUILD_COMPILER_CACHE must be on or off\n' >&2; return 2 ;;
  esac
  python_ci_cache_prepare || return $?
  local _py_ci_cache_launcher _py_ci_cache_cc _py_ci_cache_cxx
  compiler_cache_launcher_env || return $?
  _py_ci_cache_launcher="$(compiler_cache_launcher)" || return $?
  [[ -n "${_py_ci_cache_launcher}" ]] && type -P -- "${_py_ci_cache_launcher}" >/dev/null || {
    printf 'No executable compiler-cache launcher for the Python build\n' >&2; return 1;
  }
  _py_ci_cache_cc="$(python3 -c 'import shlex, sys; print(shlex.join(sys.argv[1:]))' "${_py_ci_cache_launcher}" "$CC")" || return $?
  _py_ci_cache_cxx="$(python3 -c 'import shlex, sys; print(shlex.join(sys.argv[1:]))' "${_py_ci_cache_launcher}" "$CXX")" || return $?
  CC="${_py_ci_cache_cc}" CXX="${_py_ci_cache_cxx}" "$@"
}
