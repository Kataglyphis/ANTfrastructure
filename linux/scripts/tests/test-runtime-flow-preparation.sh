#!/usr/bin/env bash
# Extracted entrypoints verify preparation order, state and error contexts, not builds, gates or publication.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/test-workspace-fixture.sh"
t_fixture_workspace_init WORK_ROOT
WORK="${WORK_ROOT}/runtime fixtures"
ORIGINAL="${1:-}"
mkdir -p "${WORK}/source" "${WORK}/caller dir" "${WORK}/repo root"
for profile in artifacts manifest; do
  cp "${ORIGINAL:-${_T_SCRIPTS}}/build-runtime-${profile}.sh" "${WORK}/source/${profile}.sh"
done
cp "${ORIGINAL:-${_T_SCRIPTS}/01-core}/runtime-flow-common.sh" "${WORK}/source/flow.sh"
cat > "${WORK}/worker.sh" <<'SH'
set -euo pipefail
source "$1"
source "${1%/*}/shell-context-fixture.sh"
work="$2" profile="$3" context="$4" dry="$5" failure="$6"
exec > "${work}/stdout" 2> "${work}/stderr"
unset _RUNTIME_FLOW_COMMON_SH_LOADED DRY_RUN CROSS_RUN_ID CROSS_BUILD_DATE CROSS_VCS_REF
source "${work}/source/flow.sh"
eval "$(t_fn_src "${work}/source/${profile}.sh" main)"
REPO_ROOT="${work}/repo root" TARGET_ARCHES=ARM64,x86_64
IMAGE_PREFIX='artifacts:tag with spaces %s' IMAGE_NAME='manifest:tag with spaces %s'
CROSS_RUN_ID=fixture-run CROSS_BUILD_DATE=fixture-date CROSS_VCS_REF=fixture-ref
case "${dry}" in unset) ;; empty) DRY_RUN='' ;; *) DRY_RUN="${dry}" ;; esac
_dry_state() { declare -p DRY_RUN 2>/dev/null || printf absent; }
_step() {
  local phase="$1"
  t_record_fixture_receipt "${work}/trace" "$@"
  printf 'OUT:%s\n' "${phase}"
  printf 'ERR:%s\n' "${phase}" >&2
  if [ "${failure}" = "${phase}" ]; then
    case "${phase}" in parse|setup) return 5 ;; wheels) return 7 ;; hailo) return 11 ;; payload) return 13 ;; esac
  fi
  return 0
}
run_runtime_arg_loop() { _step parse "$@" "$PWD" "$(_dry_state)"; }
runtime_post_parse_setup() {
  local status=0
  _step setup "$@" "$PWD" "$(_dry_state)" || status=$?
  cd "${REPO_ROOT}"
  printf -v "$1" '%s' arm64,amd64
  export RUNTIME_IMAGE_PREFIX="$2"
  return "${status}"
}
runtime_wheels_setup() { _step wheels "$PWD" "${RUNTIME_IMAGE_PREFIX}"; }
hailo_validate_knobs() { _step hailo; }
runtime_host_payload_arches() { _step payload; }
runtime_resolve_app_ref() {
  _step resolved "${TARGET_ARCHES}" "${RUNTIME_IMAGE_PREFIX}" "$PWD" "$(declare -p CROSS_RUN_ID)" "$(declare -p CROSS_BUILD_DATE)" "$(declare -p CROSS_VCS_REF)"
  exit 0
}
err() { printf 'ERROR:%s\n' "$*" >&2; exit 64; }
cd "${work}/caller dir"
shell_fixture_run_context "${context}" probe_status main --fixture 'argument with spaces'
exit "${probe_status}"
SH
diagnostic='' status=0
declare -A stop=([parse]='parse,' [setup]='parse,setup,' [wheels]='parse,setup,wheels,' [hailo]='parse,setup,wheels,hailo,' [payload]='parse,setup,wheels,hailo,payload,')
declare -A codes=([parse]=5 [setup]=5 [wheels]=7 [hailo]=2 [payload]=2)
for profile in artifacts manifest; do
  prefix="${profile}:tag with spaces %s"
  for context in direct conditional; do
    for dry in unset empty 0 1; do
      for failure in none parse setup wheels hailo payload; do
        t_case "${profile}/${context}/${dry}/${failure}"
        : > "${WORK}/trace"
        t_capture_command diagnostic status t_run_fixture_worker "${WORK}/worker.sh" "${WORK}" "${profile}" "${context}" "${dry}" "${failure}"
        expected_rc=0 expected_sequence='parse,setup,wheels,hailo,payload,resolved,'
        if [ "${failure}" != none ] && ! { [ "${context}" = conditional ] && [[ "${failure}" = parse || "${failure}" = setup ]]; }; then
          expected_rc="${codes[${failure}]}"; expected_sequence="${stop[${failure}]}"
        fi
        t_assert_eq "${expected_rc}" "${status}"
        t_assert_eq "${expected_sequence}" "$(sed 's/ .*//' "${WORK}/trace" | tr '\n' ',')"
        expected_out='' expected_err=''
        IFS=, read -r -a phases <<< "${expected_sequence}"
        for phase in "${phases[@]}"; do
          [ "${phase}" = payload ] || expected_out+="OUT:${phase}"$'\n'
          expected_err+="ERR:${phase}"$'\n'
        done
        t_assert_eq "${expected_out}." "$(cat "${WORK}/stdout"; printf '.')"
        t_assert_eq "${expected_err}." "$(cat "${WORK}/stderr"; printf '.')"
        t_assert_eq '' "${diagnostic}"
        trace="$(cat "${WORK}/trace")"
        if [[ "${expected_sequence}" = *setup,* ]]; then
          case "${dry}" in unset) declaration='declare -x DRY_RUN' ;; empty) declaration='declare -x DRY_RUN=""' ;; *) declaration="declare -x DRY_RUN=\"${dry}\"" ;; esac
          t_assert_contains "${trace}" "$(printf '%q ' setup TARGET_ARCHES "${prefix}" "${WORK}/caller dir" "${declaration}")"
        fi
        if [[ "${expected_sequence}" = *resolved,* ]]; then
          export_flag=--
          [ "${profile}" != manifest ] || export_flag=-x
          t_assert_contains "${trace}" "$(printf '%q ' resolved arm64,amd64 "${prefix}" "${WORK}/repo root" "declare ${export_flag} CROSS_RUN_ID=\"fixture-run\"" "declare ${export_flag} CROSS_BUILD_DATE=\"fixture-date\"" "declare ${export_flag} CROSS_VCS_REF=\"fixture-ref\"")"
        fi
        t_record_fixture_receipt "${RECEIPT:-}" "${profile}" "${context}" "${dry}" "${failure}" "${status}" "$(cat "${WORK}/stdout"; printf '.')" "$(cat "${WORK}/stderr"; printf '.')" "${trace}"
      done
    done
  done
done
t_case 'source-wiring assertions reject a missing preparation step'
mkdir -p "${WORK}/wiring/01-core"
for entry in build-runtime-artifacts.sh build-runtime-manifest.sh; do printf '  runtime_prepare_flow fixture\n' > "${WORK}/wiring/${entry}"; done
printf 'ANCHOR\nEXPECTED\n' > "${WORK}/wiring/01-core/runtime-flow-common.sh"
for wanted in EXPECTED MISSING; do
  t_capture_command diagnostic status bash -c 'source "$1"; source "$2"; runtime_test_preparation_step "$3" ANCHOR "$4"; t_summary' _ "${_T_SCRIPTS}/tests/test-harness.sh" "${_T_SCRIPTS}/tests/runtime-flow-fixtures.sh" "${WORK}/wiring" "${wanted}"
  expected_rc=0
  [ "${wanted}" != MISSING ] || expected_rc=1
  t_assert_eq "${expected_rc}" "${status}"
done
t_summary
