#!/usr/bin/env bash
# Container output and statuses are recorded fixtures; no image, GPU or model is exercised here.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
WORK="$(t_rt_sandbox)"
trap 'rm -rf "${WORK}"' EXIT
: "${RUNTIME_SMOKE_SOURCE:=}"
if [ -n "${RUNTIME_SMOKE_SOURCE}" ]; then
  sed '$d' "${RUNTIME_SMOKE_SOURCE}" > "${WORK}/rt.sh"
fi
# <check> <output> <status> [script dir]: the real checkout dir by default, so the GenAI check finds its generator.
_probe() {
  OUTPUT="$2" STATUS="$3" bash -c '
    source "$1/rt.sh" >/dev/null 2>&1
    _SCRIPT_DIR="$3"
    _rt_run() { case "$*" in *"GENAI_TINY_MODEL_PY="*"def successor"*) echo TINY-HANDED ;; esac; printf "%s\n" "${OUTPUT}"; return "${STATUS}"; }
    smoke_minimal_onnx_py() { :; }
    smoke_genai_py() { :; }
    _rt_versions_env_pin() { printf fixture; }
    "$2" img arm64
    printf "FAILURES=%s\n" "${FAILURES}"
  ' _ "${WORK}" "$1" "${4:-${TESTS_DIR}/../06-packaging}" 2>&1
}
for _kind in onnx genai; do
  case "${_kind}" in
    onnx) _fn=check_onnx_execution_provider; _tag=ONNX-EP; _missing=1 ;;
    genai) _fn=check_genai_binding; _tag=GENAI-BIND; _missing=0 ;;
  esac
  t_case "${_kind}: a zero status and OK sentinel pass"
  t_assert_contains "$(_probe "${_fn}" "${_tag} OK: fixture" 0)" 'FAILURES=0'
  for _status in 0 1 3 4; do
    t_case "${_kind}: status ${_status} without a sentinel fails"
    _out="$(_probe "${_fn}" 'unrelated output' "${_status}")"
    t_assert_contains "${_out}" 'FAILURES=1'
    t_assert_contains "${_out}" "printed NO ${_tag} sentinel"
  done
  for _verb in FAIL SKIP ABSENT; do
    t_case "${_kind}: a zero status with ${_verb} cannot pass"
    _out="$(_probe "${_fn}" "${_tag} ${_verb}: fixture" 0)"
    t_assert_contains "${_out}" 'FAILURES=1'
    t_assert_contains "${_out}" 'a non-OK verdict must never pass'
  done
  for _status in 1 4; do
    t_case "${_kind}: an OK sentinel cannot hide exit ${_status}"
    t_assert_contains "$(_probe "${_fn}" "${_tag} OK: fixture" "${_status}")" 'FAILURES=1'
  done
  t_case "${_kind}: missing-package status retains its lane policy"
  t_assert_contains "$(_probe "${_fn}" "${_tag} SKIP: fixture" 3)" "FAILURES=${_missing}"
done
t_case "genai: the tiny model generator reaches the container"
_out="$(_probe check_genai_binding "GENAI-BIND OK: fixture" 0)"
t_assert_contains "${_out}" 'TINY-HANDED'
t_assert_contains "${_out}" 'FAILURES=0'
t_case "genai: a checkout without the generator fails even on an OK sentinel"
mkdir -p "${WORK}/no-lib/06-packaging"
_out="$(_probe check_genai_binding "GENAI-BIND OK: fixture" 0 "${WORK}/no-lib/06-packaging")"
t_assert_contains "${_out}" "no tiny GenAI model generator at ${WORK}/no-lib/06-packaging/../lib/tiny-genai-model.py"
t_assert_contains "${_out}" 'FAILURES=1'
t_summary
