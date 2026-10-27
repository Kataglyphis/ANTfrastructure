#!/usr/bin/env bash
# Tests locked tool installation and failure propagation with uv stubs, not package resolution.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-workspace-fixture.sh"
source "${TESTS_DIR}/test-uv-fixture.sh"
declare WORK
t_fixture_workspace_init WORK || exit 1
core="${TESTS_DIR}/../01-core"
mkdir -p "${WORK}/bin" "${WORK}/venv with spaces/bin" "${WORK}/project with spaces"
printf '#!/bin/sh\nexit 0\n' > "${WORK}/venv with spaces/bin/python"
chmod +x "${WORK}/venv with spaces/bin/python"
: > "${WORK}/project with spaces/pyproject.toml"
: > "${WORK}/project with spaces/uv.lock"
t_uv_fixture_write "${WORK}/bin"
run_with_core() {
  env PATH="${WORK}/bin:${PATH}" UV_CALLS="${WORK}/calls" UV_PYTHON=wrong UV_PROJECT_ENVIRONMENT=wrong UV_WORKING_DIR=wrong UV_PROJECT=wrong \
    bash -c 'source "$1/python_uv.sh"; uv_pip_install_locked_project "$2" "$3"' _ \
      "$1" "${WORK}/venv with spaces" "${WORK}/project with spaces"
}
run_install() { run_with_core "${core}"; }
fail_export() { FAIL_EXPORT=7 run_install; }
fail_install() { FAIL_INSTALL=9 run_install; }
empty_export() { EMPTY_EXPORT=1 run_install; }
ort_export() { ORT_CHAIN_WHEEL_DIR=/chain EXPORT_PACKAGE='onnxruntime-genai[cuda]' run_install; }
t_case 'a locked export installs only its hashed packages into the selected interpreter'
: > "${WORK}/calls"
t_assert_rc 0 run_install
out="$(cat "${WORK}/calls")"
t_assert_contains "$out" 'export --project'
t_assert_contains "$out" 'project with spaces'
t_assert_contains "$out" 'venv with spaces/bin/python'
t_assert_contains "$out" '--locked'
t_assert_contains "$out" '--no-deps --require-hashes'
t_assert_eq 2 "$(printf '%s\n' "$out" | grep -c 'ENV:unset:unset:unset:unset')"
t_case 'relative project and interpreter paths remain relative to the caller'
: > "${WORK}/calls"
t_assert_rc 0 bash -c 'cd "$1"; PATH="$1/bin:$PATH" UV_CALLS="$1/calls" UV_WORKING_DIR=wrong UV_PROJECT=wrong bash -c '\''source "$1/python_uv.sh"; uv_pip_install_locked_project "venv with spaces" "project with spaces"'\'' _ "$2"' _ "${WORK}" "${core}"
t_assert_contains "$(cat "${WORK}/calls")" 'project with spaces'
t_case 'an export failure reaches the caller without starting installation'
: > "${WORK}/calls"
t_assert_rc 7 fail_export
t_assert_rc 1 grep -q 'CALL:pip' "${WORK}/calls"
t_case 'an empty export fails before installation'
: > "${WORK}/calls"
t_assert_rc 1 empty_export
t_assert_rc 1 grep -q 'CALL:pip' "${WORK}/calls"
t_case 'a tool lock cannot replace chain ONNX Runtime'
: > "${WORK}/calls"
t_assert_rc 1 ort_export
t_assert_rc 1 grep -q 'CALL:pip' "${WORK}/calls"
t_case 'an installation failure reaches the caller'
t_assert_rc 9 fail_install
t_case 'an absent lock fails before running uv'
rm "${WORK}/project with spaces/uv.lock"
: > "${WORK}/calls"
t_assert_rc 1 run_install
t_assert_eq '' "$(cat "${WORK}/calls")"
t_case 'missing or invalid cleanup companions fail before uv runs'
mkdir -p "${WORK}/bad-core"
cp "${core}/python_uv.sh" "${core}/logging.sh" "${core}/python-probe.sh" "${core}/verified-script-install.sh" "${WORK}/bad-core/"
: > "${WORK}/project with spaces/uv.lock"
: > "${WORK}/calls"
t_assert_rc 1 run_with_core "${WORK}/bad-core"
printf 'return 0\n' > "${WORK}/bad-core/uv-image-overlay.sh"
t_assert_rc 1 run_with_core "${WORK}/bad-core"
t_assert_eq '' "$(cat "${WORK}/calls")"
t_summary
