#!/usr/bin/env bash
# Exercises the real bundle's early license staging, not the later runtime or package build.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
source "${TESTS_DIR}/python-app-license-fixture.sh"
SCRIPT="${TESTS_DIR}/../06-packaging/python-app-bundle.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
python_app_license_fixture "$work/project" "$work/bundle"

_bundle() {
  env "$@" bash "$SCRIPT" --repo-root "$work/project" --out-dir "$work/bundle" \
    --work-dir "$work/work" --ort-wheel-dir "$work/no-wheels" 2>&1
}

_bundle_fails_with() {
  local expected="$1" out rc
  shift
  out="$(_bundle "$@")"; rc=$?
  t_assert_eq 1 "$rc"
  t_assert_contains "$out" "$expected"
}

t_case 'a project license is copied into the real bundle before runtime staging'
out="$(_bundle)"; rc=$?
t_assert_eq 1 "$rc"
t_assert_contains "$out" 'no chain ONNX Runtime wheel' 'the fixture stops at the later missing-wheel gate'
t_assert_eq 'Original project terms' "$(cat "$work/bundle/LICENSE")"

t_case 'a GPU image cannot claim a different execution provider'
_bundle_fails_with 'GPU image requires CUDAExecutionProvider' ENABLE_NVIDIA=true ENABLE_AMD=false PYTHON_APP_REQUIRE_PROVIDER=MIGraphXExecutionProvider
_bundle_fails_with 'no chain ONNX Runtime wheel' ENABLE_NVIDIA=true ENABLE_AMD=false PYTHON_APP_REQUIRE_PROVIDER=CUDAExecutionProvider
_bundle_fails_with 'at most one GPU image variant' ENABLE_NVIDIA=true ENABLE_AMD=true

t_case 'host GPU runtime mode is explicit and requires a GPU provider'
_bundle_fails_with 'host GPU runtime requires CUDA or MIGraphX' PYTHON_APP_HOST_GPU_RUNTIME=true
_bundle_fails_with 'host GPU runtime requires a matching GPU image variant' ENABLE_NVIDIA=false ENABLE_AMD=false PYTHON_APP_REQUIRE_PROVIDER=CUDAExecutionProvider PYTHON_APP_HOST_GPU_RUNTIME=true
_bundle_fails_with 'PYTHON_APP_HOST_GPU_RUNTIME must be true or false' PYTHON_APP_HOST_GPU_RUNTIME=invalid
_bundle_fails_with 'no chain ONNX Runtime wheel' ENABLE_AMD=true PYTHON_APP_HOST_GPU_RUNTIME=true

t_case 'missing or empty license fails before an existing bundle is reset'
printf 'keep existing bundle\n' > "$work/bundle/sentinel"
rm "$work/project/LICENSE"
out="$(_bundle)"; rc=$?
t_assert_eq 1 "$rc"
t_assert_contains "$out" 'license is missing, empty or unreadable'
t_assert_eq 'keep existing bundle' "$(cat "$work/bundle/sentinel")"
printf '  \n\t' > "$work/project/LICENSE"
out="$(_bundle)"; rc=$?
t_assert_eq 1 "$rc"
t_assert_contains "$out" 'license is missing, empty or unreadable'
t_assert_eq 'keep existing bundle' "$(cat "$work/bundle/sentinel")"
: > "$work/project/LICENSE"
out="$(_bundle)"; rc=$?
t_assert_eq 1 "$rc"
t_assert_contains "$out" 'license is missing, empty or unreadable'
t_assert_eq 'keep existing bundle' "$(cat "$work/bundle/sentinel")"

t_summary
