#!/usr/bin/env bash
# smoke-runtime-image.sh gates, extracted and run with stubbed collaborators because the script needs a live image.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SMOKE="${TESTS_DIR}/../06-packaging/smoke-runtime-image.sh"

source "${TESTS_DIR}/runtime-function-fixtures.sh"
_FN_CACHE="$(mktemp -d)"
trap 'rm -rf "${_FN_CACHE}"' EXIT
# Cases call this inside $(...), so the cache lives in files: one Python extraction per function per run, not per case.
_extract() {
  [ -s "${_FN_CACHE}/$1" ] || t_runtime_function "${SMOKE}" "$1" > "${_FN_CACHE}/$1" || { rm -f "${_FN_CACHE}/$1"; return 1; }
  cat "${_FN_CACHE}/$1"
}

# What every stubbed in-container run starts with: the smoke's pass/fail vocabulary.
_STUBS='set -u
    FAILURES=0
    fail() { printf "FAIL %s\n" "$*"; FAILURES=$((FAILURES+1)); }
    pass() { printf "PASS %s\n" "$*"; }'

# _t_edit_table <fn> [prefix]: each stdin row is <sed edit><TAB><text>; <fn> <edit> must print <prefix><text>.
_t_edit_table() {
  local _sed _want
  while IFS="$(printf '\t')" read -r _sed _want; do
    [ -n "${_sed}" ] || continue
    t_assert_contains "$("$1" "${_sed}")" "${2-}${_want}" "${_sed}"
  done
}

# _gate <fn> [healthcheck] [app smoke output] [in-image rc]
_gate() {
  local fn="$1" hc="${2-}" wheel_out="${3-}" run_rc="${4-0}" hc_json
  if [ -n "${hc}" ]; then
    hc_json="$(python3 -c 'import json,sys; print(json.dumps([{"Config":{"Healthcheck":{"Test":["CMD-SHELL",sys.argv[1]]}}}]))' "${hc}")"
  else
    hc_json='[{"Config":{}}]'
  fi
  HC_JSON="${hc_json}" WHEEL_OUT="${wheel_out}" RUN_RC="${run_rc}" bash -c '
    '"${_STUBS}"'
    # Runs the real extraction program; returning ${HC} directly would bypass the code under test.
    inspect_image_config() { printf "%s" "${HC_JSON}" | python3 -c "$1" 2>/dev/null || true; }
    _rt_run() { printf "%s\n" "${WHEEL_OUT}"; return "${RUN_RC}"; }
    _SMOKE_TORCH_EXPECTED=1
    '"$(_extract _rt_healthcheck_cmd)"'
    '"$(_extract _boot_verdict)"'
    '"$(_extract "$1")"'
    '"${fn}"' img amd64
    printf "FAILURES=%s\n" "${FAILURES}"' 2>&1
}

_functional_output() {
  local fn="$1" run_rc="$2"
  FUNCTIONAL_RUN_RC="${run_rc}" bash -c '
    '"${_STUBS}"'
    RUN_COUNT=0
    _rt_run() {
      RUN_COUNT=$((RUN_COUNT+1))
      printf "RUN_CONTEXT=<%s><%s> ARGC=%s ARGV=<%s>\n" "${image_tag}" "${target_arch}" "$#" "$1"
      printf "RUN_ARGS=<%s>\n" "$2"
      printf "RUN_COMMAND=<%s>\n" "$3"
      return "${FUNCTIONAL_RUN_RC}"
    }
    '"$(_extract _functional_smoke_gate)"'
    '"$(_extract "$1")"'
    '"$1"' img amd64
    printf "RUN_COUNT=%s\nFAILURES=%s\n" "${RUN_COUNT}" "${FAILURES}"' _ "${fn}" 2>&1
}

_assert_functional_output() {
  local fn="$1" run_rc="$2" verdict="$3" command_marker="$4" failures="$5" out
  out="$(_functional_output "${fn}" "${run_rc}")"
  t_assert_contains "${out}" "${verdict}" "${fn} keeps its exact verdict"
  t_assert_contains "${out}" "RUN_CONTEXT=<img><amd64> ARGC=3 ARGV=<bash>" "${fn} keeps image and arch in dynamic scope"
  t_assert_contains "${out}" 'RUN_ARGS=<-lc>' "${fn} keeps its shell invocation"
  t_assert_contains "${out}" "${command_marker}" "${fn} keeps its probe command"
  t_assert_contains "${out}" 'RUN_COUNT=1' "${fn} runs one probe"
  t_assert_contains "${out}" "FAILURES=${failures}" "${fn} reports only the expected gate verdict"
}

_assert_functional_output check_ffmpeg 0 'PASS ffmpeg executes (amd64)' 'set -o pipefail' 0
_assert_functional_output check_ffmpeg 1 'FAIL ffmpeg failed to execute in the runtime image (amd64)' '-version | head -1' 1
_assert_functional_output check_gstreamer_core_pipeline 0 'PASS GStreamer core pipeline runs (amd64)' 'timeout 40' 0
_assert_functional_output check_gstreamer_core_pipeline 1 'FAIL GStreamer core pipeline FAILED (amd64)' 'videotestsrc num-buffers=3' 1
_assert_functional_output check_gstreamer_mandatory_plugins 0 'PASS GStreamer mandatory plugin set loads on amd64' 'timeout 30' 0
_assert_functional_output check_gstreamer_mandatory_plugins 1 'FAIL GStreamer mandatory plugins missing/unloadable on amd64 (see MISSING: line above)' 'libav opencv onnx tflite' 1

# The three ratchet cases differ only in the summary line and what must appear.
_ratchet_says() {
  local summary="$1" want="$2" why="$3"
  t_assert_contains "$(_gate check_app_wheel_smoke "" "${summary}" 0)" "${want}" "${why}"
}

source "${TESTS_DIR}/runtime-boot-cases.sh"
source "${TESTS_DIR}/runtime-consumer-cases.sh"
source "${TESTS_DIR}/runtime-sdk-cases.sh"

t_summary
