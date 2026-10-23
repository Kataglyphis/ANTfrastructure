#!/usr/bin/env bash
# Temporary Git roots characterize scope publication and argument handoff; no lint tools or bootstraps run.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
# shellcheck source=../01-core/lint-root.sh
source "${1:-${TESTS_DIR}/../01-core/lint-root.sh}"
WORK="$(mktemp -d '/tmp/ant-lint scope.XXXXXXXX')"
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/tracked root" "${WORK}/plain"
git -C "${WORK}/tracked root" init -q
_begin_scope() {
  if declare -F lint_scope_begin >/dev/null; then
    lint_scope_begin selected_root "$@"
  else
    lint_root_begin "$@" || return 1
    selected_root="${LINT_ROOT_PATH}"
  fi
}
for scenario in default named equal repeated missing-value missing-root nongit; do
  t_case "${scenario}: scope status and remaining arguments"
  args=('file with space.py' $'line\nbreak.sh' --warning)
  expected_root="${WORK}/default root"; expected_status=0; expected_given=0
  case "${scenario}" in
    named) args=(--root "${WORK}/tracked root" "${args[@]}") ;;
    equal) args=("${args[@]}" "--root=${WORK}/tracked root") ;;
    repeated) args=(--root "${WORK}/absent" "${args[@]}" --root "${WORK}/tracked root") ;;
    missing-value) args+=(--root); expected_status=1 ;;
    missing-root) args+=(--root "${WORK}/absent"); expected_status=1 ;;
    nongit) args+=(--root "${WORK}/plain"); expected_status=1 ;;
  esac
  case "${scenario}" in named|equal|repeated) expected_root="${WORK}/tracked root"; expected_given=1 ;; esac
  selected_root=unchanged; status=0
  _begin_scope "${WORK}/default root" "${args[@]}" > "${WORK}/output" 2>&1 || status=$?
  t_assert_eq "${expected_status}" "${status}"
  if [ "${expected_status}" = 0 ]; then
    t_assert_eq "${expected_root}" "${selected_root}"
    t_assert_eq "${expected_given}" "${LINT_ROOT_GIVEN}"
    t_assert_eq 3 "${#LINT_ROOT_REST[@]}"
    t_assert_eq 'file with space.py' "${LINT_ROOT_REST[0]}"
    t_assert_eq $'line\nbreak.sh' "${LINT_ROOT_REST[1]}"
    t_assert_eq --warning "${LINT_ROOT_REST[2]}"
  else
    t_assert_eq unchanged "${selected_root}" 'failed scope resolution never publishes a fallback root'
  fi
done
t_case 'scope publication does not export its output variable'
t_assert_eq unset "$(bash -c 'printf "%s" "${selected_root-unset}"')"
t_summary
