# shellcheck shell=bash
# Source remains unconditional so selected-module failures keep the entry point's errexit policy.
_bootstrap_source_first() {
  local -n _bsf_found="$1"
  local _bsf_candidate
  shift
  _bsf_found=0
  for _bsf_candidate in "$@"; do
    if [ -f "${_bsf_candidate}" ]; then
      # shellcheck source=/dev/null
      source "${_bsf_candidate}"
      _bsf_found=1
      break
    fi
  done
  return 0
}

bootstrap_script_modules() {
  local caller_dir="$1" _bsm_found
  shift
  _bootstrap_source_first _bsm_found "$@"
  [ "${_bsm_found}" -eq 1 ] || { echo 'Error: modules.sh not found' >&2; exit 1; }
  source_modules_framework "${caller_dir}"
}

source_required_symbol() {
  local symbol="$1" diagnostic="$2" _srs_found
  shift 2
  _bootstrap_source_first _srs_found "$@"
  command -v "${symbol}" >/dev/null 2>&1 \
    || { printf '%s\n' "${diagnostic}" >&2; exit 1; }
}
