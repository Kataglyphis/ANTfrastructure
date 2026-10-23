#!/usr/bin/env bash
# Lane queries use repository-relative paths so native Windows Python sees the same checkout as Git Bash.
_WORKFLOW_FIXTURE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_WORKFLOW_FIXTURE_DIR}/test-harness.sh"

workflow_lane_fixture_init() {
  ROOT="$(cd "${_WORKFLOW_FIXTURE_DIR}/../../.." && pwd)" || return 1
  LANE="${ROOT}/$1"
  _WORKFLOW_BUILD_JOB="$2" _WORKFLOW_FOCUS_JOB="$3"
  local IFS=$' \t\n'
  read -r -a _WORKFLOW_PYTHON <<< "${4//$'\n'/ }"
}

_q() {
  (cd "${ROOT}" && "${_WORKFLOW_PYTHON[@]}" linux/scripts/tests/workflow-lane-query.py \
    "${LANE#"${ROOT}/"}" "${_WORKFLOW_BUILD_JOB}" "${_WORKFLOW_FOCUS_JOB}" "$1") 2>&1
}

workflow_assert_input_fields() {
  local input="$1" field expected
  shift
  while [ "$#" -gt 0 ]; do
    field="$1" expected="$2"
    shift 2
    t_assert_eq "$expected" "$(_q "V.value(V.value(inputs,'${input}'),'${field}')")"
  done
}
