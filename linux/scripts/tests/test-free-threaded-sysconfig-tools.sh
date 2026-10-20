#!/usr/bin/env bash
# The X.Yt tree's sysconfig names only compiler tools the image runs; see docs/consumer-image-contract.md#the-free-threaded-python
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
t_skip_unless "a POSIX python3" t_posix_python
SCRIPTS="$(cd "${TESTS_DIR}/.." && pwd)"
FIXER="${SCRIPTS}/06-packaging/free-threaded-sysconfig-tools.py"
TORCH="${SCRIPTS}/../Dockerfile.torch"

_work="$(mktemp -d)"; trap 'rm -rf "${_work}"' EXIT
_tool() { mkdir -p "$(dirname "$1")"; printf '#!/bin/sh\n' > "$1"; chmod +x "$1"; }

# <prefix> <gcc-bin>: a cross-built 3.14t tree as the riscv64 image ships it, the toolchain stage's paths recorded.
_tree() {
  local lib="$1/lib/python3.14t" g="$2/riscv64-linux-gnu"
  mkdir -p "${lib}/config-3.14t-riscv64-linux-gnu"
  cat > "${lib}/_sysconfigdata_t_linux_riscv64-linux-gnu.py" <<EOF
# system configuration generated and used by the sysconfig module
build_time_vars = {'AR': '${g}-ar',
 'CC': '${g}-gcc',
 'CXX': '${g}-g++',
 'GCC_AR': '${g}-gcc-ar',
 'LDSHARED': '${g}-gcc -shared -L/usr/lib/riscv64-linux-gnu',
 'LINKCC': '${g}-gcc',
 'Py_GIL_DISABLED': 1}
EOF
  printf '{"AR": "%s-ar", "CC": "%s-gcc"}\n' "${g}" "${g}" > "${lib}/_sysconfig_vars_t_linux_riscv64-linux-gnu.json"
  printf 'AR=\t\t%s-ar\nCC=\t\t%s-gcc\n' "${g}" "${g}" > "${lib}/config-3.14t-riscv64-linux-gnu/Makefile"
}
_fix() { PATH="${_work}/path:/usr/bin:/bin" python3 -I "${FIXER}" "$@"; }
_data() { cat "$1"/lib/python3.14t/_sysconfigdata_t_*.py; }

t_case "the riscv64 image: its GCC prefix has gcc and g++ but no ar, which binutils puts on PATH"
_tool "${_work}/gcc/bin/riscv64-linux-gnu-gcc"; _tool "${_work}/gcc/bin/riscv64-linux-gnu-g++"
_tool "${_work}/path/riscv64-linux-gnu-ar"
_tree "${_work}/t1" "${_work}/gcc/bin"
_out="$(t_out _fix check "${_work}/t1")"
t_assert_eq 1 "$(t_rc _fix check "${_work}/t1")"
t_assert_contains "${_out}" "names tools this image lacks: AR=${_work}/gcc/bin/riscv64-linux-gnu-ar"
t_assert_eq 0 "$(grep -c 'CC=' <<<"${_out}")" "an existing absolute tool is fine"

t_case "fix points the missing tool at its PATH twin in the data, its JSON twin and the Makefile, then checks"
_out="$(t_out _fix fix "${_work}/t1")"
t_assert_eq 0 "$(t_rc _fix check "${_work}/t1")" "${_out}"
t_assert_contains "${_out}" "every compiler tool _sysconfigdata_t_linux_riscv64-linux-gnu.py names runs here"
t_assert_contains "$(_data "${_work}/t1")" "'AR': 'riscv64-linux-gnu-ar',"
t_assert_contains "$(_data "${_work}/t1")" "'CC': '${_work}/gcc/bin/riscv64-linux-gnu-gcc',"
t_assert_contains "$(cat "${_work}"/t1/lib/python3.14t/_sysconfig_vars_t_*.json)" '"AR": "riscv64-linux-gnu-ar"'
t_assert_contains "$(cat "${_work}"/t1/lib/python3.14t/config-*/Makefile)" $'AR=\t\triscv64-linux-gnu-ar'
t_assert_eq 0 "$(t_rc _fix fix "${_work}/t1")" "a second fix finds nothing to do"

t_case "a swapped path is replaced whole, never inside a longer tool name"
_tool "${_work}/path/riscv64-linux-gnu-gcc"
_tree "${_work}/t2" "${_work}/gone/bin"
_out="$(t_out _fix fix "${_work}/t2")"
t_assert_contains "$(_data "${_work}/t2")" "'CC': 'riscv64-linux-gnu-gcc',"
t_assert_contains "$(_data "${_work}/t2")" "'GCC_AR': '${_work}/gone/bin/riscv64-linux-gnu-gcc-ar',"
t_assert_contains "$(_data "${_work}/t2")" "'LDSHARED': 'riscv64-linux-gnu-gcc -shared -L/usr/lib/riscv64-linux-gnu',"
t_assert_contains "${_out}" "names tools this image lacks: CXX=${_work}/gone/bin/riscv64-linux-gnu-g++"
t_assert_eq 1 "$(t_rc _fix fix "${_work}/t2")" "a tool with no twin on PATH stays missing, and fails"

t_case "a prefix without exactly one free-threaded sysconfigdata, or a wrong verb, is refused"
mkdir -p "${_work}/empty/lib/python3.14t"
t_assert_contains "$(t_out _fix check "${_work}/empty")" "holds 0 lib/python3.*t/_sysconfigdata_t_*.py, want 1"
t_assert_eq 2 "$(t_rc _fix verify "${_work}/t1")"

t_case "the torch stage fixes the shipped tree before the uv cache seed builds on it"
_torch="$(cat "${TORCH}")"
t_assert_contains "${_torch}" "free-threaded-sysconfig-tools.py fix /opt/python-freethreaded"
_fix_at="$(grep -n 'free-threaded-sysconfig-tools.py fix' "${TORCH}" | head -1 | cut -d: -f1)"
_seed_at="$(grep -n 'uv-cache-seed.sh build' "${TORCH}" | head -1 | cut -d: -f1)"
t_assert_eq 0 "$(t_rc test "${_fix_at:-0}" -gt 0 -a "${_fix_at:-0}" -lt "${_seed_at:-0}")" "fix at line ${_fix_at:-none}, seed at ${_seed_at:-none}"

t_summary
