#!/usr/bin/env bash
# smoke-runtime-image.sh gates, extracted and run with stubbed collaborators because the script needs a live image.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SMOKE="${TESTS_DIR}/../06-packaging/smoke-runtime-image.sh"

source "${TESTS_DIR}/runtime-function-fixtures.sh"
_extract() { t_runtime_function "${SMOKE}" "$1"; }

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

# The three ratchet cases differ only in the summary line and what must appear.
_ratchet_says() {
  local summary="$1" want="$2" why="$3"
  t_assert_contains "$(_gate check_app_wheel_smoke "" "${summary}" 0)" "${want}" "${why}"
}

source "${TESTS_DIR}/runtime-boot-cases.sh"
source "${TESTS_DIR}/runtime-consumer-cases.sh"
source "${TESTS_DIR}/runtime-sdk-cases.sh"

t_summary
