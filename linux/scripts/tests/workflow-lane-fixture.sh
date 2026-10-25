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

workflow_assert_artifact_step() {
  local name="$1" path="$2" condition="${3:-}" query
  query="next(s for s in steps if V.value(s,'name') == '${name}')"
  t_assert_contains "$(_q "V.value(${query},'if')")" 'always()'
  [ -z "${condition}" ] || t_assert_contains "$(_q "V.value(${query},'if')")" "${condition}"
  t_assert_contains "$(_q "V.value(${query},'uses')")" 'actions/upload-artifact@'
  t_assert_eq "True" "$(_q "V.value(V.value(${query},'with'),'path') == '${path}'")"
  t_assert_eq "True" "$(_q "V.value(V.value(${query},'with'),'if-no-files-found') == 'error'")"
}

workflow_require_queries() {
  local expression result
  for expression in "$@"; do
    result="$(_q "${expression}")" || {
      printf 'workflow query failed: %s\n%s\n' "${expression}" "${result}" >&2
      return 1
    }
    if [ "${result}" != True ]; then
      printf 'workflow query was not true: %s\n%s\n' "${expression}" "${result}" >&2
      return 1
    fi
  done
}
