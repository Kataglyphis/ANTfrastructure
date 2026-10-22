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
t_summary
