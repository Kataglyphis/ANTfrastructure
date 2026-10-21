#!/usr/bin/env bash
# The cross-wheel sysconfig export describes the BUILD TARGET and the pinned interpreter, never the host's triple or stdlib (`cp315`, `cp314`, `linux_x86_64`, 2026-10-19).
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
WHEELHOUSE_SH="${TESTS_DIR}/../05-frameworks/torch/build-app-wheelhouse.sh"

_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT
APP_WHEELHOUSE_BUILD_ROOT="${_work}/build"
BUILD_PYTHON="$(command -v python3)"
export BUILD_PYTHON

# A GIL cross tree as staged: the host's data, no target-named sysconfigdata, and a json that refuses to load so a PYTHONPATH leak shows.
_sysroot="${_work}/sysroot"
mkdir -p "${_sysroot}/lib/python3.14/json"
printf 'build_time_vars = {"SOABI": "cpython-314-x86_64-linux-gnu"}\n' \
    > "${_sysroot}/lib/python3.14/_sysconfigdata__linux_x86_64-linux-gnu.py"
printf 'raise SystemExit("the target stdlib was imported through PYTHONPATH")\n' \
    > "${_sysroot}/lib/python3.14/json/__init__.py"

cross_target_triplet_for_arch() { if [ "$1" = riscv64 ]; then printf 'riscv64-linux-gnu'; fi; }
cross_target_python_root() { printf '%s' "${_sysroot}"; }
warn() { printf 'WARN %s\n' "$*" >&2; }
eval "$(t_fn_src "${TESTS_DIR}/../01-core/cross-python.sh" cross_target_sysconfigdata_dir)"
eval "$(t_fn_src "${WHEELHOUSE_SH}" resolve_target_python_sysconfig_export)"
eval "$(t_fn_src "${TESTS_DIR}/../05-frameworks/tvm-python.sh" _tvm_target_python_sysconfig_export)"

t_case "the export names the build target, not the host"
_out="$(TARGET_ARCH=riscv64 resolve_target_python_sysconfig_export)"
t_assert_contains "${_out}" "_PYTHON_SYSCONFIGDATA_NAME=_sysconfigdata__linux_riscv64-linux-gnu" \
    "the target sysconfigdata module must be named"
t_assert_contains "${_out}" "_PYTHON_HOST_PLATFORM=linux_riscv64" \
    "the wheel platform must be the target's"
t_assert_contains "${_out}" "PYTHONPATH=${APP_WHEELHOUSE_BUILD_ROOT}/sysconfigdata-riscv64-linux-gnu" \
    "PYTHONPATH must be the dedicated dir, not a stdlib"
t_assert_eq 0 "$(printf '%s' "${_out}" | grep -cF "x86_64")" \
    "nothing host-shaped may survive in the export"

t_case "a GIL tree without target data still yields a target-tagged build"
t_needs "a POSIX python3 (Windows' sysconfig never reads _PYTHON_SYSCONFIGDATA_NAME)" t_posix_python
printf '%s\n' "${_out}" > "${_work}/export.sh"
t_assert_ok env -u PYTHONPATH bash -c \
    "source '${_work}/export.sh'; python3 -c 'import sysconfig; v = sysconfig.get_config_var(\"SOABI\"); raise SystemExit(0 if v and v.endswith(\"-riscv64-linux-gnu\") else 1)'" \
    "the synthesised data must describe the target"
t_assert_ok env -u PYTHONPATH bash -c \
    "source '${_work}/export.sh'; python3 -c 'import json; raise SystemExit(1 if json.__file__.startswith(\"${_sysroot}\") else 0)'" \
    "the target stdlib must not shadow the pinned interpreter's json"

t_case "no target arch means no export"
t_assert_eq "" "$( (unset TARGET_ARCH TARGETARCH; resolve_target_python_sysconfig_export) )" \
    "without TARGET_ARCH there is nothing to describe"

# Both exports find the module through cross_target_sysconfigdata_dir (01-core/cross-python.sh, CON114).
_tgt="_sysconfigdata__linux_riscv64-linux-gnu"
mkdir -p "${_sysroot}/lib/python3.14/lib-dynload"
printf 'build_time_vars = {"SOABI": "cpython-314-riscv64-linux-gnu", "STAGED": 1}\n' \
    > "${_sysroot}/lib/python3.14/lib-dynload/${_tgt}.py"

t_case "a target module in the staged tree is copied, not synthesised"
rm -rf "${APP_WHEELHOUSE_BUILD_ROOT}"
TARGET_ARCH=riscv64 resolve_target_python_sysconfig_export >/dev/null
t_assert_contains "$(cat "${APP_WHEELHOUSE_BUILD_ROOT}/sysconfigdata-riscv64-linux-gnu/${_tgt}.py" 2>&1)" '"STAGED": 1' \
    "the staged target's own data must win over a synthesised copy"

t_case "TVM's export points at the staged target module's dir"
cross_build_is_active() { :; }
cross_target_triplet() { printf 'riscv64-linux-gnu'; }
t_assert_eq "export _PYTHON_SYSCONFIGDATA_NAME=${_tgt}; export PYTHONPATH=${_sysroot}/lib/python3.14/lib-dynload\${PYTHONPATH:+:\${PYTHONPATH}}" \
    "$(_tvm_target_python_sysconfig_export 2>&1)" "tvm-ffi's Cython core must take the target's SOABI"
rm -f "${_sysroot}/lib/python3.14/lib-dynload/${_tgt}.py"

t_summary
