#!/usr/bin/env bash
# Two gates in smoke-runtime-image.sh that could not fail, and now can:
#   * the app-wheel ratchet fell back to exit-status-only when its ok-count did
#     not parse -- the very thing it exists to distrust (backlog WF);
#   * the HEALTHCHECK gates ran a hardcoded copy of the probe and read only
#     Test[0], the OCI verb, so a wrong HEALTHCHECK shipped green (backlog WE).
# smoke-runtime-image.sh runs against a live image, so the functions are
# extracted and their collaborators stubbed.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SMOKE="${TESTS_DIR}/../06-packaging/smoke-runtime-image.sh"

_extract() {
  awk -v f="$1" '$0 ~ "^"f"\\(\\) \\{" {p=1} p {print} p && /^\}/ {exit}' "${SMOKE}"
}

# One run of a gate with its collaborators stubbed. HC is what the image reports
# as its healthcheck; WHEEL_OUT is what the app smoke prints; RUN_RC is what a
# command executed in the image returns.
_gate() {
  local fn="$1" hc="${2-}" wheel_out="${3-}" run_rc="${4-0}" hc_json
  if [ -n "${hc}" ]; then
    hc_json="$(python3 -c 'import json,sys; print(json.dumps([{"Config":{"Healthcheck":{"Test":["CMD-SHELL",sys.argv[1]]}}}]))' "${hc}")"
  else
    hc_json='[{"Config":{}}]'
  fi
  HC_JSON="${hc_json}" WHEEL_OUT="${wheel_out}" RUN_RC="${run_rc}" bash -c '
    set -u
    FAILURES=0
    fail() { printf "FAIL %s\n" "$*"; FAILURES=$((FAILURES+1)); }
    pass() { printf "PASS %s\n" "$*"; }
    # Runs the REAL extraction program against a fixture, exactly as the live
    # helper does. Returning ${HC} directly would bypass the code under test.
    inspect_image_config() { printf "%s" "${HC_JSON}" | python3 -c "$1" 2>/dev/null || true; }
    _rt_run() { printf "%s\n" "${WHEEL_OUT}"; return "${RUN_RC}"; }
    _SMOKE_TORCH_EXPECTED=1
    '"$(_extract _rt_healthcheck_cmd)"'
    '"$(_extract "$1")"'
    '"${fn}"' img amd64
    printf "FAILURES=%s\n" "${FAILURES}"' 2>&1
}

# The three ratchet cases differ only in the summary line and what must appear.
_ratchet_says() {
  local summary="$1" want="$2" why="$3"
  t_assert_contains "$(_gate check_app_wheel_smoke "" "${summary}" 0)" "${want}" "${why}"
}

t_case "an unreadable ok-count fails instead of falling back to the exit status"
_ratchet_says "=== 15/15 passed, 0 failure(s) ===" "could not read the ok-count" \
  "a summary the ratchet cannot parse must fail, not pass with '?'"

t_case "a degraded count still fails"
_ratchet_says "=== 12/15 ok, 3 failure(s) ===" "degraded" "below the floor must fail"

t_case "a full count passes"
_ratchet_says "=== 15/15 ok, 0 failure(s) ===" "PASS app wheel smoke passed" \
  "at the floor must pass"

# ── WE: the healthcheck ──────────────────────────────────────────────────────
t_case "the healthcheck gate reads the command, not the OCI verb"
_out="$(_gate check_healthcheck_config '/opt/venv/bin/python3 -c "import onnxruntime" || exit 1')"
t_assert_contains "${_out}" "import onnxruntime" \
  "the configured probe itself must appear, not just CMD-SHELL"

t_case "a HEALTHCHECK with no command fails"
_out="$(_gate check_healthcheck_config "")"
t_assert_contains "${_out}" "FAIL" "an empty command must fail"

t_case "the exec gate runs the image's own command and reports it"
_out="$(_gate check_healthcheck_exec '/opt/venv/bin/python3 -c "import onnxruntime" || exit 1' "" 1)"
t_assert_contains "${_out}" "import onnxruntime" \
  "a failing healthcheck must name the command it actually ran"

t_summary
