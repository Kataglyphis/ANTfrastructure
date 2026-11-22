#!/usr/bin/env bash
# The real VM probe tests child ownership across Dart/Rust, not inference, packaging or kernel-blocked cleanup.
set -euo pipefail
scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=linux/scripts/lib/cli-value-options.sh
source "${scripts}/lib/cli-value-options.sh"
cli_require_positionals 'NEW_OUTPUT [--expect-status-loss|--idle-reaper|--teardown-negative-control|--module-owner-negative-control]' 1 2 "$@"
mode=()
hip_leak_device=46
module_control=0
if [[ "$#" == 2 ]]; then
  case "$2" in
    --expect-status-loss|--idle-reaper) mode=("$2") ;;
    --teardown-negative-control) hip_leak_device=47 ;;
    --module-owner-negative-control) module_control=1 ;;
    *) printf 'Unknown probe mode\n' >&2; exit 2 ;;
  esac
fi
root="$(cd "${scripts}/../.." && pwd)"
# shellcheck source=linux/scripts/lib/isolated-helper-compile.sh
source "${scripts}/lib/isolated-helper-compile.sh"
mkdir "$1"
output="$(cd "$1" && pwd)"
rustc --version > "${output}/rust-version.txt"
dart --version > "${output}/dart-version.txt" 2>&1
compile_isolated_helper_object "${root}" "${output}"
compile_isolated_hip_fixtures "${root}" "${output}"
rustc --edition=2021 --deny warnings --crate-type cdylib \
  -C "link-arg=${output}/isolated-helper.o" \
  "${root}/shared/rust/tests/dart_child_owner_probe.rs" -o "${output}/libchild-owner-probe.so"
module_path="${output}/libchild-owner-probe.so"
if [[ "${module_control}" == 1 ]]; then module_path="${output}/hip-worker"; fi
result=0
env ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 LSAN_OPTIONS=exitcode=86 \
  ANT_TEST_HIP_WORKER="${output}/hip-worker" ANT_TEST_HIP_RUNTIME="${output}/libhip-fixture.so" \
  ANT_TEST_HIP_LEAK_DEVICE="${hip_leak_device}" \
  ANT_TEST_MODULE_PATH="${module_path}" \
  dart run "${root}/shared/rust/tests/dart_child_owner_probe.dart" \
  "${output}/libchild-owner-probe.so" "${mode[@]}" > "${output}/result.json" 2> "${output}/worker-stderr.log" || result=$?
cat "${output}/worker-stderr.log" >&2
cat "${output}/result.json"
[[ "${result}" == 0 ]] || exit "${result}"
if [[ "${mode[0]:-}" != --expect-status-loss ]]; then require_isolated_hip_report "${output}/worker-stderr.log"; fi
exit 0
