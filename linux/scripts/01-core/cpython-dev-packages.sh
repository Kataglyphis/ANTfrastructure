# shellcheck shell=bash
# Source-only helper -- do not execute directly.
# cpython-dev-packages.sh - THE single table tying CPython's external-library
# stdlib extension modules to the apt -dev packages they link against.
#
# Structural parity (backlog TS3): before this table there were three
# independently hand-maintained truths -- the HOST dev-package list
# (package-lists.sh base_image_os_packages), the CROSS-target install list
# (02-toolchain/python/build_python.sh), and the extension-assert lists
# (build_python.sh cross staging + smoke-toolchain.sh). The 2026-08-09
# libsqlite3-dev incident was exactly this desync: the host closure only got
# sqlite transitively (via GUI dev packages), the cross list forgot it, and no
# assert noticed. All of those sites now derive from this table, so a
# PYTHON_VERSION bump or a new extension dependency cannot desync host and
# target again.
#
# Row format: "<dev-package> <required|optional> <ext-module>[ <ext-module>...]"
#   required - the target-arch dev-package install is FATAL on cross staging,
#              and the listed extension .so files MUST land in lib-dynload.
#   optional - tolerated when apt cannot install the package or the extension
#              is deliberately not built; asserts are warn-only.

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
  # The uuid stdlib module falls back to pure Python without _uuid.
  "uuid-dev optional _uuid"
)

# All parsing below pins IFS=' ' on the read builtin: several consumers
# (build_python.sh) run under IFS=$'\n\t', where an unpinned read would NOT
# split the space-separated row fields.

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
cpython_ext_dev_packages_optional() { _cpython_dev_pkgs_by_class optional; }

_cpython_ext_modules_by_class() {
  local want="$1" row pkg class exts ext
  local -a ext_arr=()
  for row in "${_CPYTHON_EXT_DEV_PKG_TABLE[@]}"; do
    IFS=' ' read -r pkg class exts <<< "${row}"
    [ "${class}" = "${want}" ] || continue
    IFS=' ' read -r -a ext_arr <<< "${exts}"
    for ext in "${ext_arr[@]}"; do
      printf '%s\n' "${ext}"
    done
  done
  return 0
}

# Extension modules whose backing dev package is required/optional above.
cpython_ext_modules_required() { _cpython_ext_modules_by_class required; }
cpython_ext_modules_optional() { _cpython_ext_modules_by_class optional; }
