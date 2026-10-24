#!/usr/bin/env bash
# Local shells characterize probe transport and metadata policy; no registry, container engine or real consumer payload runs.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
RUNTIME="${1:-${TESTS_DIR}/../06-packaging/smoke-runtime-image.sh}"
CONTRACT="${TESTS_DIR}/../06-packaging/runtime-consumer-contract.sh"
t_source_functions "${CONTRACT}" check_consumer_contract _consumer_probe_verdict || exit 1
t_source_functions "${RUNTIME}" run_shipped_truth_probe \
  check_entrypoint check_workdir check_volume || exit 1
for helper in _rt_image_config_value _rt_run_shell_probe _rt_config_value_verdict; do
  if grep -Eq "^${helper}\(\)" "${RUNTIME}"; then eval "$(t_fn_src "${RUNTIME}" "${helper}")"; fi
done
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
pass() { printf 'PASS:%s\n' "$*"; }
fail() { printf 'FAIL:%s\n' "$*"; FAILURES=$((FAILURES + 1)); }
inspect_image_config() { printf '%s' "${CONFIG_JSON}" | python3 -c "$1"; }
_consumer_contract_probe() { printf '%s' "${PROGRAM}"; }
_shipped_truth_probe() { printf '%s' "${PROGRAM}"; }
_consumer_contract_verdicts() { printf 'OK fixture held\nASSERTED 1\n'; }
_rt_run() {
  printf '%s' "$2" > "${WORK}/environment"
  printf '%s' "$5" > "${WORK}/command"
  if [ "${TRANSPORT_MODE}" = empty ]; then
    env "${2%%=*}=" "${@:3}"
  else
    env "$2" "${@:3}"
  fi
}
CONFIG_JSON='[{"Config":{"User":"kataglyphis","Entrypoint":["/entry point"],"WorkingDir":"/work space","Volumes":{"/cache path":{}}}}]'
for gate in consumer shipped; do
  for scenario in complete empty incomplete nonzero; do
    t_case "${gate} probe: ${scenario} transport"
    FAILURES=0; TRANSPORT_MODE=normal
    if [ "${gate}" = consumer ]; then
      PROGRAM='printf "%s\n" "WHO 1001 kataglyphis" "CCPROBE_DONE"'
      variable=RT_CONTRACT_SH; marker=CCPROBE_EMPTY
      expected_command='if [ -z "${RT_CONTRACT_SH:-}" ]; then echo "CCPROBE_EMPTY"; exit 4; fi
printf "%s\n" "${RT_CONTRACT_SH}" | bash'
    else
      PROGRAM='printf "%s\n" "PKG one" "REQ edge" "RTPROBE_DONE"'
      variable=RT_PROBE_SH; marker=RTPROBE_EMPTY
      expected_command='if [ -z "${RT_PROBE_SH:-}" ]; then echo "RTPROBE_EMPTY"; exit 4; fi
printf "%s\n" "${RT_PROBE_SH}" | bash'
    fi
    case "${scenario}" in
      empty) TRANSPORT_MODE=empty ;;
      incomplete) PROGRAM='printf "%s\n" "partial output"' ;;
      nonzero) PROGRAM="${PROGRAM}; exit 9" ;;
    esac
    if [ "${gate}" = consumer ]; then
      check_consumer_contract 'fixture image' arm64 > "${WORK}/output" 2>&1
      if [ "${scenario}" = empty ] || [ "${scenario}" = incomplete ]; then
        t_assert_eq 1 "${FAILURES}"
        t_assert_contains "$(cat "${WORK}/output")" 'asserted NOTHING'
      else
        t_assert_eq 0 "${FAILURES}"
        t_assert_contains "$(cat "${WORK}/output")" '1 row(s) hold as kataglyphis on arm64'
      fi
    else
      _SHIPPED_TRUTH_PROBE=''; _SHIPPED_TRUTH_PROBE_RC=1
      run_shipped_truth_probe 'fixture image' arm64 > "${WORK}/output" 2>&1
      if [ "${scenario}" = empty ] || [ "${scenario}" = incomplete ]; then
        t_assert_eq 1 "${_SHIPPED_TRUTH_PROBE_RC}"
        t_assert_contains "$(cat "${WORK}/output")" 'no RTPROBE_DONE marker'
      else
        t_assert_eq 0 "${_SHIPPED_TRUTH_PROBE_RC}"
        t_assert_contains "$(cat "${WORK}/output")" '1 venv distributions, 1 requirement edges'
      fi
      if [ "${scenario}" = empty ]; then t_assert_eq "${marker}" "${_SHIPPED_TRUTH_PROBE}"; fi
    fi
    t_assert_eq "${expected_command}" "$(cat "${WORK}/command")" 'shell wrapper bytes remain unchanged'
    t_assert_eq "${variable}=${PROGRAM}" "$(cat "${WORK}/environment")" 'payload bytes cross the environment boundary intact'
  done
done
t_case 'entrypoint remains required while WORKDIR absence is informational'
FAILURES=0
check_entrypoint fixture arm64 > "${WORK}/output"
t_assert_contains "$(cat "${WORK}/output")" "Entrypoint configured: ['/entry point']"
check_workdir fixture arm64 > "${WORK}/output"
t_assert_contains "$(cat "${WORK}/output")" 'WORKDIR: /work space'
check_volume fixture arm64 > "${WORK}/output"
t_assert_contains "$(cat "${WORK}/output")" 'VOLUME: /cache path'
CONFIG_JSON='[{"Config":{}}]'
check_entrypoint fixture arm64 > "${WORK}/output"
t_assert_eq 1 "${FAILURES}"
t_assert_contains "$(cat "${WORK}/output")" 'No entrypoint configured'
check_workdir fixture arm64 > "${WORK}/output"
t_assert_eq 1 "${FAILURES}"
t_assert_contains "$(cat "${WORK}/output")" 'INFO: No WORKDIR set'
check_volume fixture arm64 > "${WORK}/output"
t_assert_contains "$(cat "${WORK}/output")" 'INFO: No VOLUME set'
t_assert_eq 1 "${FAILURES}"
CONFIG_JSON='[{"Config":{"WorkingDir":"NONE"}}]'
check_workdir fixture arm64 > "${WORK}/output"
t_assert_contains "$(cat "${WORK}/output")" 'PASS:WORKDIR: NONE'
t_summary
