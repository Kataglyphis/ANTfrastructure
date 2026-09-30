# shellcheck shell=bash
# The one table of CPython extension modules and their -dev packages: docs/failure-modes.md#a-from-source-cpython-silently-drops-an-extension-module

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "This script is meant to be sourced, not executed" >&2
  exit 1
fi

[ -z "${_CPYTHON_DEV_PACKAGES_LOADED:-}" ] || return 0
_CPYTHON_DEV_PACKAGES_LOADED=1

# Row: "<dev-package> <required|optional> <ext-module>..."; a missing required package is fatal on cross staging.
_CPYTHON_EXT_DEV_PKG_TABLE=(
  "zlib1g-dev required zlib"
  "libbz2-dev required _bz2"
  "liblzma-dev required _lzma"
  # New in 3.14; optional until a full cross rebuild proves it on every target.
  "libzstd-dev optional _zstd"
  # _ctypes is disabled on cross builds (ac_cv_header_ffi_h=no); the header stays for host/target parity.
  "libffi-dev optional _ctypes"
  "libssl-dev required _ssl _hashlib"
  # Without it CPython silently drops _sqlite3, which much of the ecosystem imports.
  "libsqlite3-dev required _sqlite3"
  # Line editing and history for an interactive python3.
  "libreadline-dev required readline"
  # Optional until a full cross rebuild proves it on every target.
  "libncurses-dev optional _curses"
  # The uuid stdlib module falls back to pure Python without _uuid.
  "uuid-dev optional _uuid"
  # Required would switch every arch to a dynamic libmpdec.so; promote before 3.16 drops the bundled copy.
  "libmpdec-dev optional _decimal"
)

# Reads pin IFS=' ': build_python.sh runs under IFS=$'\n\t', where a bare read does not split a row.
cpython_ext_dev_packages() {
  local row pkg _rest
  for row in "${_CPYTHON_EXT_DEV_PKG_TABLE[@]}"; do
    IFS=' ' read -r pkg _rest <<< "${row}"
    printf '%s\n' "${pkg}"
  done
}

_cpython_dev_pkgs_by_class() {
  local want="$1" row pkg class _rest
  for row in "${_CPYTHON_EXT_DEV_PKG_TABLE[@]}"; do
    IFS=' ' read -r pkg class _rest <<< "${row}"
    [ "${class}" = "${want}" ] && printf '%s\n' "${pkg}"
  done
  return 0
}

cpython_ext_dev_packages_required() { _cpython_dev_pkgs_by_class required; }

# Every extension module the table names, one per line; a row may name several.
cpython_ext_modules() {
  local row pkg class mods
  local -a mod_words
  for row in "${_CPYTHON_EXT_DEV_PKG_TABLE[@]}"; do
    IFS=' ' read -r pkg class mods <<< "${row}"
    IFS=' ' read -r -a mod_words <<< "${mods}"
    if [ "${#mod_words[@]}" -gt 0 ]; then
      printf '%s\n' "${mod_words[@]}"
    fi
  done
}
