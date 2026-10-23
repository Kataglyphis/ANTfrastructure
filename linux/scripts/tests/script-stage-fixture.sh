#!/usr/bin/env bash
# Stage fixtures share source selection and workspace cleanup while retaining their own tool stubs.
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"

script_stage_fixture_init() {
  local -n workspace="$1" selected_source="$2"
  case "$3" in
    40-build-wasm.sh) selected_source="${4:-${TESTS_DIR}/../03-media/build/onnxruntime/build/40-build-wasm.sh}" ;;
    build-android.sh) selected_source="${4:-${TESTS_DIR}/../03-media/build/iree/android/build-android.sh}" ;;
    *) return 2 ;;
  esac
  [ -f "$selected_source" ] || { printf 'ERROR: fixture source missing: %s\n' "$selected_source" >&2; return 1; }
  shift 4
  workspace="$(mktemp -d)" || return 1
  _SCRIPT_STAGE_FIXTURE_WORK="$workspace"
  trap 'rm -rf -- "${_SCRIPT_STAGE_FIXTURE_WORK}"' EXIT
  local dir
  for dir in "$@"; do mkdir -p "$workspace/$dir" || return 1; done
}
