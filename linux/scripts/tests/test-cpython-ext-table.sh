#!/usr/bin/env bash
# Tests for 01-core/cpython-dev-packages.sh — the one table tying CPython's
# extension modules to the apt -dev packages they link against, and the two
# consumers that must both read it (the target install, the lib-dynload audit).
# docs/failure-modes.md
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
source "${TESTS_DIR}/../01-core/cpython-dev-packages.sh"
BUILD_PY="${TESTS_DIR}/../02-toolchain/python/build_python.sh"

# The table read by a second, independent parser: awk over the raw rows.
_awk_col() { printf '%s\n' "${_CPYTHON_EXT_DEV_PKG_TABLE[@]}" | awk -v c="$1" \
  '{ if (c == "pkg") print $1; else if (c == "class") print $2; else for (i = 3; i <= NF; i++) print $i }'; }

t_case "the package accessors agree with the raw rows"
t_assert_eq "$(_awk_col pkg)" "$(cpython_ext_dev_packages)"
t_assert_eq "$(_awk_col class | grep -c -e '^required$')" "$(cpython_ext_dev_packages_required | wc -l)"

t_case "cpython_ext_modules yields every module the rows name, in row order"
t_assert_eq "$(_awk_col mod)" "$(cpython_ext_modules)"

t_case "a row naming two modules yields both, adjacent"
t_assert_contains "$(cpython_ext_modules | tr '\n' ' ')" "_ssl _hashlib" \
  "libssl-dev covers _ssl AND _hashlib"

t_case "the split survives the consumer's IFS (build_python.sh runs under \$'\\n\\t')"
# The historical trap the table header names: an unpinned `read` under that IFS
# does not split on spaces, so a two-module row would arrive as one word.
t_assert_eq "$(cpython_ext_modules)" "$(IFS=$'\n\t'; cpython_ext_modules)"
t_assert_eq "$(cpython_ext_dev_packages)" "$(IFS=$'\n\t'; cpython_ext_dev_packages)"

t_case "the hand-maintained list the audit used to carry is fully covered"
# build_python.sh:365 held (zlib _bz2 _lzma _ssl _hashlib _ctypes _sqlite3) and had
# never gained readline, which LOG23 added to the table — the desync this closes.
_mods=" $(cpython_ext_modules | tr '\n' ' ')"
for _m in zlib _bz2 _lzma _ssl _hashlib _ctypes _sqlite3; do
  t_assert_contains "${_mods}" " ${_m} " "the audit still covers ${_m}"
done
t_assert_contains "${_mods}" " readline " "and now covers readline too"

t_case "the lib-dynload audit derives its list, and keeps no second copy"
t_assert_eq "1" "$(grep -c -e 'done < <(cpython_ext_modules)' "${BUILD_PY}")"
t_assert_eq "0" "$(grep -c -e '_optional_exts' "${BUILD_PY}")" "no second extension-module list"

t_case "required-ness is still enforced on the PACKAGE, not on the .so"
t_assert_eq "1" "$(grep -c -e 'cpython_ext_dev_packages_required' "${BUILD_PY}")"
t_assert_contains "$(grep -A2 -e 'if \[ -n "${_missing}" \]' "${BUILD_PY}")" "err " \
  "a missing REQUIRED dev package is fatal; a missing .so only warns"

t_summary
