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
  bash "$SCRIPT" --repo-root "$work/project" --out-dir "$work/bundle" \
    --work-dir "$work/work" --ort-wheel-dir "$work/no-wheels" 2>&1
}

t_case 'a project license is copied into the real bundle before runtime staging'
out="$(_bundle)"; rc=$?
t_assert_eq 1 "$rc"
t_assert_contains "$out" 'no chain ONNX Runtime wheel' 'the fixture stops at the later missing-wheel gate'
t_assert_eq 'Original project terms' "$(cat "$work/bundle/LICENSE")"

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
