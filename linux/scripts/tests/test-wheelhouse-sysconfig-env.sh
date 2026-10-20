#!/usr/bin/env bash
# The cross-wheel sysconfig export exposes only the target's sysconfigdata: its 3.14 stdlib under 3.15 killed the IREE arm64 wheelhouse (2026-10-19).
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
WHEELHOUSE_SH="${TESTS_DIR}/../05-frameworks/torch/build-app-wheelhouse.sh"

_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT
APP_WHEELHOUSE_BUILD_ROOT="${_work}/build"

# The sysconfigdata beside a stdlib whose json refuses to load, so a leak of that dir onto PYTHONPATH shows.
_sysroot="${_work}/sysroot"
mkdir -p "${_sysroot}/lib/python3.14/json"
printf 'build_time_vars = {"SOABI": "cpython-314-riscv64-linux-gnu"}\n' \
    > "${_sysroot}/lib/python3.14/_sysconfigdata__linux_riscv64-linux-gnu.py"
printf 'raise SystemExit("the target stdlib was imported through PYTHONPATH")\n' \
    > "${_sysroot}/lib/python3.14/json/__init__.py"

cross_target_triplet() { printf 'riscv64-linux-gnu'; }
cross_target_python_root() { printf '%s' "${_sysroot}"; }
warn() { printf 'WARN %s\n' "$*" >&2; }
eval "$(t_fn_src "${WHEELHOUSE_SH}" resolve_target_python_sysconfig_export)"

t_case "the export names the module and a sysconfigdata-only directory"
_out="$(resolve_target_python_sysconfig_export)"
t_assert_contains "${_out}" "_PYTHON_SYSCONFIGDATA_NAME=_sysconfigdata__linux_riscv64-linux-gnu" \
    "the target sysconfigdata module must be named"
t_assert_contains "${_out}" "PYTHONPATH=${APP_WHEELHOUSE_BUILD_ROOT}/sysconfigdata-riscv64-linux-gnu" \
    "PYTHONPATH must be the dedicated dir, not the target stdlib"
t_assert_eq 0 "$(printf '%s' "${_out}" | grep -cF "${_sysroot}/lib/python3.14")" \
    "the target's lib/python3.14 must never reach PYTHONPATH"

t_case "the pinned interpreter reads the target's SOABI and keeps its own json"
printf '%s\n' "${_out}" > "${_work}/export.sh"
t_assert_ok env -u PYTHONPATH bash -c \
    "source '${_work}/export.sh'; python3 -c 'import sysconfig; raise SystemExit(0 if sysconfig.get_config_var(\"SOABI\") == \"cpython-314-riscv64-linux-gnu\" else 1)'" \
    "the target sysconfigdata must be the one sysconfig reads"
t_assert_ok env -u PYTHONPATH bash -c \
    "source '${_work}/export.sh'; python3 -c 'import json; raise SystemExit(1 if json.__file__.startswith(\"${_sysroot}\") else 0)'" \
    "the target stdlib must not shadow the pinned interpreter's json"

t_case "a missing sysconfigdata falls back to the host sysconfig instead of a foreign path"
cross_target_python_root() { printf '%s' "${_work}/absent"; }
_out_absent="$(resolve_target_python_sysconfig_export 2>/dev/null)"
t_assert_eq "" "${_out_absent}" "no target data means no export at all"

t_summary
