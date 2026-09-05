# shellcheck shell=bash
# Source-only helper -- do not execute directly.
# cpython-dev-packages.sh - THE table tying CPython's stdlib extension modules to
# the apt -dev packages they link against. Three consumers derive from it and none
# may keep a second list; the class governs the PACKAGE (a missing required one is
# fatal on cross staging), while a missing .so only ever warns.
# docs/failure-modes.md#a-from-source-cpython-silently-drops-an-extension-module
#
# Row format: "<dev-package> <required|optional> <ext-module>[ <ext-module>...]"

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "This script is meant to be sourced, not executed" >&2
  exit 1
fi

[ -z "${_CPYTHON_DEV_PACKAGES_LOADED:-}" ] || return 0
_CPYTHON_DEV_PACKAGES_LOADED=1

_CPYTHON_EXT_DEV_PKG_TABLE=(
  "zlib1g-dev required zlib"
  "libbz2-dev required _bz2"
  "liblzma-dev required _lzma"
  # compression.zstd is new in CPython 3.14; keep optional until a full cross
  # rebuild has proven _zstd builds on every target, then promote to required.
  "libzstd-dev optional _zstd"
  # _ctypes is deliberately disabled on cross builds (ac_cv_header_ffi_h=no in
  # build_python.sh's config.site), so the extension stays warn-only although
  # the header package is still installed for host/target parity.
  "libffi-dev optional _ctypes"
  "libssl-dev required _ssl _hashlib"
  # The 2026-08-09 incident package: a from-source CPython silently drops
  # _sqlite3 when libsqlite3-dev is absent at configure time, and half the
  # Python ecosystem imports sqlite3 transitively.
  "libsqlite3-dev required _sqlite3"
  # readline makes an interactive python3 usable at all (line editing, history).
  # Was missing from all arches — LOG23.
  "libreadline-dev required readline"
  # _curses was missing on cross arches — LOG23. Optional until a full cross
  # rebuild proves it builds on every target, then promote to required.
  "libncurses-dev optional _curses"
  # The uuid stdlib module falls back to pure Python without _uuid.
  "uuid-dev optional _uuid"
  # LOG18: CPython 3.14 falls back to bundled libmpdec (deprecated, removal
  # scheduled for 3.16) when libmpdec-dev is absent. Optional for now — the
  # row is NOT free: promoting to required flips all three arches from
  # bundled-static to a dynamic libmpdec.so, with so-package-map consequences.
  # Harmless today (3.14.7 pinned, 3.16 ~Oct 2027); promote before 3.16.
  "libmpdec-dev optional _decimal"
)

# Every read below pins IFS=' ': build_python.sh runs under IFS=$'\n\t', where
# an unpinned read does not split a row into fields at all.

# Every dev package in the table, one per line.
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
