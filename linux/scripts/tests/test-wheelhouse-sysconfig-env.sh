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

# A GIL cross tree as staged: the host's data, no target-named sysconfigdata, and a json that refuses to load so a PYTHONPATH leak shows.
_sysroot="${_work}/sysroot"
mkdir -p "${_sysroot}/lib/python3.14/json"
printf 'build_time_vars = {"SOABI": "cpython-314-x86_64-linux-gnu"}\n' \
    > "${_sysroot}/lib/python3.14/_sysconfigdata__linux_x86_64-linux-gnu.py"
printf 'raise SystemExit("the target stdlib was imported through PYTHONPATH")\n' \
    > "${_sysroot}/lib/python3.14/json/__init__.py"

cross_target_triplet_for_arch() { [ "$1" = riscv64 ] && printf 'riscv64-linux-gnu'; }
cross_target_python_root() { printf '%s' "${_sysroot}"; }
warn() { printf 'WARN %s\n' "$*" >&2; }
eval "$(t_fn_src "${WHEELHOUSE_SH}" resolve_target_python_sysconfig_export)"

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

t_summary
