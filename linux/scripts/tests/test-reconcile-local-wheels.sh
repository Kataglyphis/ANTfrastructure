#!/usr/bin/env bash
# CHARACTERISATION tests for reconcile_local_wheels: they pin the sequence of uv
# invocations it makes for a given set of local wheels, so the 128-line function
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
for _fn in wheel_family _purge_shadowing_pypi_builds _wheel_families_present \
          _partition_wheels_by_install_group _install_wheel_groups \
          _backfill_torch_runtime_deps reconcile_local_wheels; do
  awk -v f="${_fn}" '$0 ~ "^"f"\\(\\) \\{" {p=1} p {print} p && /^\}/ {exit}' "${SUBJECT}" >> "${_lib}"
done

# Run it over a wheel set and print every uv call, one per line.
# One harness. The torch backfill needs
# a venv python whose imports we control, and the IREE split needs uname.
# $1 = arch reported by uname -m, $2 = space-separated modules that DO import.
_uv_calls_env() {
  local arch="$1" importable="$2"; shift 2
  local d="${_work}/wheels2"; rm -rf "${d}"; mkdir -p "${d}"
  local w; for w in "$@"; do : > "${d}/${w}"; done
  local venv="${_work}/venv"; rm -rf "${venv}"; mkdir -p "${venv}/bin"
  # A python3 that succeeds only for the named modules, so the backfill list is ours.
  { printf '#!/usr/bin/env bash\n'
    printf 'for m in %s; do [ "$2" = "import ${m}" ] && exit 0; done\n' "${importable}"
    printf 'exit 1\n'; } > "${venv}/bin/python3"
  chmod +x "${venv}/bin/python3"
  LOCAL_WHEELS_DIR="${d}" VIRTUAL_ENV="${venv}" _T_ARCH="${arch}" bash -c '
    set -eu
    log() { :; }; warn() { :; }; echo() { :; }
    uname() { printf "%s\n" "${_T_ARCH}"; }
    uv() { printf "uv %s\n" "$*"; }
    uv_uninstall_pip_opencv() { printf "uninstall-pip-opencv\n"; }
    staged_opencv_python_available() { return 1; }
    source "'"${_lib}"'"
    reconcile_local_wheels
  ' 2>/dev/null
}

# The original harness is this one with the defaults the first four cases used.
_uv_calls() { _uv_calls_env x86_64 "" "$@"; }

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


t_case "a torch wheel backfills exactly the deps that do NOT import"
_out="$(_uv_calls_env x86_64 "sympy mpmath networkx jinja2 markupsafe filelock" \
        "torch-2.13.0-cp314-cp314-linux_x86_64.whl")"
# Match the uv CALL, not the "Backfilling ..." notice: that notice is a printf,
# which this harness does not stub, so a substring test alone passes with the
# install deleted. Mutation-proven 2026-09-03.
_bf="$(printf '%s\n' "${_out}" | grep -e '^uv pip install --no-deps ' | grep -v -e '\.whl')"
t_assert_contains "${_bf}" "fsspec" "fsspec does not import, so it must be backfilled"
t_assert_contains "${_bf}" "typing-extensions" "the PACKAGE name is installed, not the module name"

t_case "nothing is backfilled when every torch dep already imports"
_out="$(_uv_calls_env x86_64 "sympy mpmath networkx jinja2 markupsafe filelock fsspec typing_extensions" \
        "torch-2.13.0-cp314-cp314-linux_x86_64.whl")"
t_assert_eq "" "$(printf '%s\n' "${_out}" | grep -e '^uv pip install --no-deps ' | grep -v -e '\.whl' | grep -v -e 'ml_dtypes')"

t_case "a non-torch wheel set never enters the backfill at all"
_out="$(_uv_calls_env x86_64 "" "numpy-2.5.2-cp314-cp314-linux_x86_64.whl")"
t_assert_eq "" "$(printf '%s\n' "${_out}" | grep -e '^uv pip install --no-deps ' | grep -v -e '\.whl' | grep -v -e 'ml_dtypes')"

t_case "a non-torch wheel set returns 0 under set -e (the amd64/arm64 path)"
# 2026-09-03: a trailing `[ torch ] && backfill` made the function return 1 for
# every arch WITHOUT a local torch wheel; set -e then killed setup-torch-venv.sh
# silently after the last uv call. docs/failure-modes.md#a-trailing-conditional-fails-the-whole-script
_uv_calls_env x86_64 "" "numpy-2.5.2-cp314-cp314-linux_x86_64.whl" >/dev/null
t_assert_eq 0 "$?" "reconcile_local_wheels must exit 0 when there is nothing to backfill"

t_case "IREE on riscv64 builds ml_dtypes from source — WITH deps"
_out="$(_uv_calls_env riscv64 "" "iree_base_runtime-3.11.0-cp312-abi3-linux_riscv64.whl")"
t_assert_contains "${_out}" "uv pip install ml_dtypes" "riscv64 has no wheel, so deps must resolve"

t_case "IREE elsewhere takes the wheel and skips resolution"
_out="$(_uv_calls_env x86_64 "" "iree_base_runtime-3.11.0-cp312-abi3-linux_x86_64.whl")"
t_assert_contains "${_out}" "uv pip install --no-deps ml_dtypes" "--no-deps is the non-riscv64 path"

t_case "install ORDER is other -> tvm -> iree, which the venv gate depends on"
_out="$(_uv_calls_env x86_64 "" "numpy-2.5.2-cp314-cp314-linux_x86_64.whl" \
        "tvm-0.26.0-cp314-cp314-linux_x86_64.whl" \
        "iree_base_runtime-3.11.0-cp312-abi3-linux_x86_64.whl")"
t_assert_eq "numpy tvm iree" "$(printf '%s\n' "${_out}" | grep -oE -e 'numpy|tvm|iree' | awk '!seen[$0]++' | tr '\n' ' ' | sed 's/ $//')"

t_case "a torch wheel triggers the shadowing purge"
_out="$(_uv_calls_env x86_64 "sympy mpmath networkx jinja2 markupsafe filelock fsspec typing_extensions" \
        "torch-2.13.0-cp314-cp314-linux_x86_64.whl")"
t_assert_contains "${_out}" "torch" "the torch wheel itself is force-reinstalled"

t_summary
