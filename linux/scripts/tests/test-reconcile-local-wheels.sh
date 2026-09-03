#!/usr/bin/env bash
# CHARACTERISATION tests for reconcile_local_wheels: they pin the sequence of uv
# invocations it makes for a given set of local wheels, so the 139-line function
# can be decomposed (backlog F1) and proven unchanged. They describe what it DOES.
#
# The function reads its wheels from /opt/wheels, which is root-owned, so it was
# untestable off-target until the directory became overridable via
# LOCAL_WHEELS_DIR (unset, it is exactly /opt/wheels).
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SUBJECT="${TESTS_DIR}/../03-media/runtime/assemble-torch-app.sh"

_work="$(mktemp -d)"; trap 'rm -rf "${_work}"' EXIT

# Extract the function and its wheel_family helper: assemble-torch-app.sh is a
# top-level script and sourcing it would run the whole assembly.
_lib="${_work}/lib.sh"
for _fn in wheel_family _purge_shadowing_pypi_builds reconcile_local_wheels; do
  awk -v f="${_fn}" '$0 ~ "^"f"\\(\\) \\{" {p=1} p {print} p && /^\}/ {exit}' "${SUBJECT}" >> "${_lib}"
done

# Run it over a wheel set and print every uv call, one per line.
_uv_calls() {
  local d="${_work}/wheels"; rm -rf "${d}"; mkdir -p "${d}"
  local w; for w in "$@"; do : > "${d}/${w}"; done
  LOCAL_WHEELS_DIR="${d}" bash -c '
    set -u
    log() { :; }; warn() { :; }; echo() { :; }
    uv() { printf "uv %s\n" "$*"; }
    uv_uninstall_pip_opencv() { printf "uninstall-pip-opencv\n"; }
    staged_opencv_python_available() { return 1; }
    source "'"${_lib}"'"
    reconcile_local_wheels
  ' 2>/dev/null
}

t_case "no local wheels means uv sync's result is kept untouched"
# Weak by construction, and recorded as such: with no wheels the loop body never
# runs either, so this cannot tell an early return from nothing-to-do. It still
# guards a future change that WOULD install something on an empty set.
t_assert_eq "" "$(_uv_calls)" "an empty wheel dir must produce no uv call at all"

t_case "ordinary wheels are force-reinstalled with --no-deps"
_out="$(_uv_calls "numpy-2.5.2-cp314-cp314-linux_x86_64.whl")"
t_assert_contains "${_out}" "--no-deps --force-reinstall" \
  "--no-deps is what stops uv re-resolving the lock (numpy/protobuf MAJOR float)"

t_case "the ORT runtime deps ride along with a local ORT wheel"
_out="$(_uv_calls "onnxruntime-1.29.0-cp314-cp314-linux_x86_64.whl")"
t_assert_contains "${_out}" "protobuf>=6,<7" "the wheel declares it and --no-deps skips it"
t_assert_contains "${_out}" "flatbuffers" "same for the second dangling edge"

t_case "IREE and TVM are partitioned out, not force-reinstalled with the rest"
_out="$(_uv_calls "iree_base_runtime-3.11.0-cp312-abi3-linux_riscv64.whl" "tvm-0.26.0-cp314-cp314-linux_x86_64.whl")"
t_assert_contains "${_out}" "tvm" "TVM is optional and installed on its own"
t_assert_contains "${_out}" "iree" "IREE likewise"

t_summary
