#!/usr/bin/env bash
# Argument parsing and real help paths are covered; packaging, uv downloads and app launchers are outside this suite.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
LIB="${TESTS_DIR}/../06-packaging/python-app-cli.sh"
_parse() {
  bash -c '
    set -eu
    source "$1"; shift
    usage() { echo USAGE; }
    REPO_ROOT=default-root CONFIG=default-config OUT_DIR=default-out WORK_DIR=default-work
    WHEEL_DIR=default-wheel PYTHON_VERSION=default-python ORT_WHEEL_DIR=default-ort
    BUNDLE=default-bundle FORMATS=default-formats RUN_TESTS=true
    parse_python_app_args "$@"
    printf "<%s>" "${REPO_ROOT}" "${CONFIG}" "${OUT_DIR}" "${WORK_DIR}" "${WHEEL_DIR}" "${PYTHON_VERSION}" "${ORT_WHEEL_DIR}" "${BUNDLE}" "${FORMATS}" "${RUN_TESTS}"
  ' _ "${LIB}" "$@" 2>&1
}
t_case "a bundle accepts each of its options with spaces intact"
t_assert_eq '<repo root><app config><output dir><work dir><wheel dir><3.14.0><ort wheels><default-bundle><default-formats><true>' \
  "$(_parse bundle --repo-root 'repo root' --config 'app config' --out-dir 'output dir' --work-dir 'work dir' --wheel-dir 'wheel dir' --python-version 3.14.0 --ort-wheel-dir 'ort wheels')"
t_case "a package accepts its own options and no-test switch"
t_assert_eq '<repo root><app config><output dir><work dir><default-wheel><default-python><default-ort><bundle dir><tar,deb><false>' \
  "$(_parse package --repo-root 'repo root' --config 'app config' --out-dir 'output dir' --work-dir 'work dir' --bundle 'bundle dir' --formats tar,deb --no-test)"
t_case "the last repeated value wins"
t_assert_contains "$(_parse bundle --config first --config second)" '<second>'
for mode in bundle package; do
  t_case "${mode}: help returns before parsing later unknown options"
  t_assert_eq USAGE "$(_parse "${mode}" --help --unknown)"
  t_assert_eq 0 "$(t_rc _parse "${mode}" --help)"
  t_case "${mode}: a missing or empty value fails"
  t_assert_eq 1 "$(t_rc _parse "${mode}" --repo-root)"
  t_assert_eq 1 "$(t_rc _parse "${mode}" --config '')"
  t_case "${mode}: unknown options fail with usage"
  t_assert_eq 2 "$(t_rc _parse "${mode}" --unknown)"
  t_assert_eq 2 "$(t_rc _parse "${mode}" '')"
  t_assert_eq USAGE "$(_parse "${mode}" --unknown)"
  t_case "${mode}: the real driver loads its sibling parser for help"
  t_assert_contains "$(bash "${TESTS_DIR}/../06-packaging/python-app-${mode}.sh" --help)" 'usage:'
done
t_case "bundle rejects package-only switches and values"
t_assert_eq 2 "$(t_rc _parse bundle --bundle dir)"
t_assert_eq 2 "$(t_rc _parse bundle --no-test)"
t_case "package rejects bundle-only options"
t_assert_eq 2 "$(t_rc _parse package --wheel-dir dir)"
t_assert_eq 2 "$(t_rc _parse package --python-version 3.14.0)"

t_case "AMD's deviceless error stands in for a registration only where no ROCm device exists"
_dev() { bash -c 'source "$1"; shift; python_app_deviceless_args "$@"' _ "${LIB}" "$@"; }
_nokfd="$(mktemp -u)"
t_assert_eq $'--deviceless-plugin-error\nHIP failure 100: no ROCm-capable device is detected' "$(_dev MIGraphX "${_nokfd}")"
t_assert_eq '' "$(_dev MIGraphX /dev/null)" "a character device at the path is the GPU"
t_assert_eq '' "$(_dev CUDAExecutionProvider "${_nokfd}")" "CUDA's EP registers on import and needs no stand-in"

t_case "the self-test gets the provider's flags and never the image's AMD module root"
# _st [args...]: python_app_selftest under a python3 that prints its arguments and what it sees of ORT_AMDGPU_EP_ROOT.
_st() {
  ORT_AMDGPU_EP_ROOT=/usr/local/lib/onnxruntime-ep-amdgpu bash -c 'source "$1"; shift
    python3() { printf "<%s>" "$@"; printf " root=%s\n" "${ORT_AMDGPU_EP_ROOT-unset}"; }
    python_app_deviceless_args() { if [ "$1" = MIGraphX ]; then printf "%s\n" --deviceless-plugin-error "no device"; fi; }
    python_app_selftest "$@"' _ "${LIB}" "$@"
}
t_assert_eq '<checker><--root></b><--require-registered-plugin><MIGraphX><--deviceless-plugin-error><no device><--><app><--self-test> root=unset' \
  "$(_st checker /b MIGraphX app --self-test)"
t_assert_eq '<checker><--root></b><--require-available-provider><CUDAExecutionProvider><--><app> root=unset' "$(_st checker /b CUDAExecutionProvider app)"
t_assert_eq '<checker><--root></b><--><app> root=unset' "$(_st checker /b '' app)" "a CPU bundle requires no provider"
t_assert_contains "$(PYTHON_APP_REQUIRE_ACTIVE_PROVIDER=true _st checker /b MIGraphX app)" '<--require-provider><MIGraphX>'
t_summary
