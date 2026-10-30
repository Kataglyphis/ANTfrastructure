#!/usr/bin/env bash
# Exercises group selection and argument transport with a stub; real uv resolution is outside this fixture.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
UV_SH="${1:-${TESTS_DIR}/../01-core/python_uv.sh}"
t_source_functions "${UV_SH}" _uv_group_ort_guard _uv_sync_args uv_sync_project || exit 1
WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/bin" "${WORK}/venv/bin" "${WORK}/venv/lib" "${WORK}/project"
printf '#!/usr/bin/env bash\nexit 0\n' > "${WORK}/venv/bin/python"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "$UV_TEST_LOG"\nprintf "env=%%s python=%%s active=%%s\\n" "${UV_PROJECT_ENVIRONMENT:-}" "${UV_PYTHON:-unset}" "${VIRTUAL_ENV:-unset}" >> "$UV_TEST_LOG"\n' > "${WORK}/bin/uv"
chmod +x "${WORK}/bin/uv" "${WORK}/venv/bin/python"
export PATH="${WORK}/bin:${PATH}" UV_TEST_LOG="${WORK}/calls"
export UV_PYTHON=/foreign/python VIRTUAL_ENV=/foreign/venv
_CURRENT_VENV_PATH="${WORK}/venv"
info() { :; }
warn() { :; }
_uv_sync_extra_args() { local -n extra_args="$1"; extra_args+=(--all-extras); }
_uv_chain_ort_skip_args() { local -n skip_args="$1"; skip_args+=(--no-install-package onnxruntime); }
uv_reconcile_chain_ort() { printf 'reconcile=%s skipped=%s\n' "$1" "${_UV_CHAIN_ORT_SKIPPED:-}" >> "${UV_TEST_LOG}"; }
cd "${WORK}/project" || exit 1
touch uv.lock

t_case "only-group keeps the locked environment and does not install the project, dev group, extras or lock-wide ORT"
_UV_CHAIN_ORT_SKIPPED=stale
t_assert_ok uv_sync_project --locked --only-group docs
calls="$(cat "${UV_TEST_LOG}")"
t_assert_contains "${calls}" $'sync\n--only-group\ndocs\n--locked'
t_assert_contains "${calls}" "env=${WORK}/venv python=unset active=unset"
t_assert_contains "${calls}" "reconcile=${WORK}/venv skipped="
t_assert_fails grep -E '^--(dev|all-extras|no-install-package)$' "${UV_TEST_LOG}"

t_case "multiple groups retain their argument boundaries"
t_assert_ok uv_sync_project --only-group docs --only-group lint
t_assert_contains "$(cat "${UV_TEST_LOG}")" $'--only-group\ndocs\n--only-group\nlint'

t_case "missing group name fails before starting uv"
rm -f "${UV_TEST_LOG}"
t_assert_fails uv_sync_project --only-group
t_assert_fails test -e "${UV_TEST_LOG}"
t_assert_fails uv_sync_project --only-group --locked
t_assert_fails test -e "${UV_TEST_LOG}"

t_case "a chain group sync refuses a lock containing ORT before uv can install it"
printf '[[package]]\nname = "onnxruntime-gpu"\n' > uv.lock
ORT_CHAIN_WHEEL_DIR="${WORK}/chain" t_assert_fails uv_sync_project --locked --only-group docs
t_assert_fails test -e "${UV_TEST_LOG}"
printf "[[package]]\nname='onnxruntime'\n" > uv.lock
ORT_CHAIN_WHEEL_DIR="${WORK}/chain" t_assert_fails uv_sync_project --locked --only-group docs
t_assert_fails test -e "${UV_TEST_LOG}"
printf 'bad = [\n' > uv.lock
ORT_CHAIN_WHEEL_DIR="${WORK}/chain" t_assert_fails uv_sync_project --locked --only-group docs
t_assert_fails test -e "${UV_TEST_LOG}"
rm uv.lock
ORT_CHAIN_WHEEL_DIR="${WORK}/chain" t_assert_fails uv_sync_project --locked --only-group docs
t_assert_fails test -e "${UV_TEST_LOG}"
touch uv.lock
ORT_CHAIN_WHEEL_DIR="${WORK}/chain" t_assert_ok uv_sync_project --locked --only-group docs

t_case "the existing default still includes dev, extras and chain exclusions"
t_assert_ok uv_sync_project
t_assert_contains "$(cat "${UV_TEST_LOG}")" $'sync\n--dev\n--all-extras\n--locked\n--no-install-package\nonnxruntime'

t_case "chain exclusions read Windows CRLF locks as well as Linux LF locks"
t_source_functions "${UV_SH}" _uv_chain_ort_skip_args || exit 1
printf '[[package]]\r\nname = "onnxruntime"\r\n[[package]]\r\nname = "onnxruntime-gpu"\r\n[[package]]\r\nname = "onnxruntimeother"\r\n' > uv.lock
args=()
ORT_CHAIN_WHEEL_DIR="${WORK}/chain" _uv_chain_ort_skip_args args
t_assert_eq "${args[*]}" '--no-install-package onnxruntime --no-install-package onnxruntime-gpu'
t_assert_eq "${_UV_CHAIN_ORT_SKIPPED}" 'onnxruntime onnxruntime-gpu '
printf '[[package]]\nname = "onnxruntime"\n' > uv.lock
args=()
ORT_CHAIN_WHEEL_DIR="${WORK}/chain" _uv_chain_ort_skip_args args
t_assert_eq "${args[*]}" '--no-install-package onnxruntime'
t_summary
