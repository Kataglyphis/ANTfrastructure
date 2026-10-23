#!/usr/bin/env bash
# Stubbed npm and filesystem fixtures cover step control flow, not real web bundles or lockfile contents.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
STEP="${1:-${TESTS_DIR}/../03-media/build/onnxruntime/build/50-build-js.sh}"
_work=$(mktemp -d)
trap 'rm -rf "$_work"' EXIT

_fixture() {
  local dir="$1"
  mkdir -p "$dir/lib" "$dir/src/js/common" "$dir/src/js/web" "$dir/wasm"
  cp "$STEP" "$dir/step.sh"
  cp "${TESTS_DIR}/../01-core/logging.sh" "$dir/lib/logging.sh"
  for kind in asyncify jspi; do
    printf fixture > "$dir/wasm/ort-wasm-simd-threaded.$kind.mjs"
    printf fixture > "$dir/wasm/ort-wasm-simd-threaded.$kind.wasm"
  done
  cat > "$dir/lib/common.sh" <<'SH'
parse_common_args() { :; }
detect_jobs() { :; }
is_amd64_arch() { return 0; }
source "$(dirname "${BASH_SOURCE[0]}")/logging.sh"
sleep() { printf 'sleep:%s\n' "$*" >> "$fixture_log"; }
rm() { local IFS=' '; printf 'cleanup:%s\n' "$*" >> "$fixture_log"; }
cp() {
  if [[ "$fixture_drop_copy" == true && "${!#}" == "$WASM_OUTPUT_DIR/" ]]; then return 1; fi
  command cp "$@"
}
declare -A fixture_attempts=()
npm() {
  local label="${PWD#"$ORT_SRC_DIR/"}" count
  local IFS=' '
  printf 'npm:%s:%s\n' "$label" "$*" >> "$fixture_log"
  if [[ "$1" == ci ]]; then
    count=$(( ${fixture_attempts[$label]:-0} + 1 ))
    fixture_attempts[$label]=$count
    if [[ "$fixture_fail_at" == "$label" ]]; then
      [[ "$fixture_fail" == once && "$count" -gt 1 ]]
      return $?
    fi
    return 0
  fi
  if [[ "$fixture_build_failure" == true ]]; then return 1; fi
  command rm -f "$ORT_SRC_DIR/js/web/dist/"*.mjs "$WASM_OUTPUT_DIR/"*.mjs
  if [[ "$fixture_artifact" != none ]]; then
    printf bundle > "$ORT_SRC_DIR/js/web/dist/ort.$fixture_artifact"
  fi
}
SH
}

_run() {
  local dir="$1"; shift
  _rc=0
  env ORT_SRC_DIR="$dir/src" WASM_OUTPUT_DIR="$dir/wasm" fixture_log="$dir/calls" \
    fixture_fail_at='' fixture_fail=never fixture_artifact=js fixture_drop_copy=false fixture_build_failure=false \
    "$@" bash "$dir/step.sh" > "$dir/output" 2>&1 || _rc=$?
  _output=$(cat "$dir/output")
  _calls=$(cat "$dir/calls")
}

for extension in js mjs; do
  t_case "$extension-only bundles are accepted and copied"
  dir="$_work/$extension"; _fixture "$dir"
  _run "$dir" "fixture_artifact=$extension"
  t_assert_eq 0 "$_rc" "$_output"
  t_assert_eq bundle "$(cat "$dir/wasm/ort.$extension")"
  t_assert_contains "$_calls" $'npm:js:ci\nnpm:js/common:ci\nnpm:js/web:ci\nnpm:js/web:run build'
  t_assert_contains "$_calls" "cleanup:-rf $dir/src/js/node_modules"
done

for label in js js/common js/web; do
  for failure in once always; do
    t_case "$label lockfile retry: $failure"
    dir="$_work/${label//\//-}-$failure"; _fixture "$dir"
    _run "$dir" "fixture_fail_at=$label" "fixture_fail=$failure"
    t_assert_eq 2 "$(grep -c "^npm:$label:ci$" "$dir/calls")"
    t_assert_eq 1 "$(grep -c '^sleep:5$' "$dir/calls")"
    t_assert_contains "$_output" "npm ci failed in $label/ — retrying once"
    t_assert_eq 0 "$(grep -c 'npm:.*:install' "$dir/calls" || true)" 'lockfile-exact installs only'
    if [[ "$failure" == once ]]; then
      t_assert_eq 0 "$_rc" "$_output"
    else
      t_assert_eq 1 "$_rc" "$_output"
      t_assert_contains "$_output" "npm ci failed twice in $label/ (lockfile-exact install is mandatory)"
      t_assert_eq 0 "$(grep -c ':run build$' "$dir/calls" || true)" 'failed installs must stop the build'
    fi
  done
done

for verdict in absent copy-failed build-failed; do
  t_case "$verdict cannot report a successful JS build"
  dir="$_work/$verdict"; _fixture "$dir"
  case "$verdict" in
    absent) _run "$dir" fixture_artifact=none; expected='No .js or .mjs files found' ;;
    copy-failed) _run "$dir" fixture_drop_copy=true; expected='JS artifacts copy failed' ;;
    build-failed) _run "$dir" fixture_build_failure=true; expected='npm run build failed' ;;
  esac
  t_assert_eq 1 "$_rc" "$_output"
  t_assert_contains "$_output" "$expected"
  t_assert_eq 0 "$(grep -c '^cleanup:' "$dir/calls" || true)" 'failures stop before success cleanup'
done

t_summary
