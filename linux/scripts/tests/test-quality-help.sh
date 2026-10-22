#!/usr/bin/env bash
# Header cleanup must preserve usable help without exposing script bodies.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"

t_case "rootless binfmt help names every supported mode"
out="$(bash "${TESTS_DIR}/../setup-rootless-binfmt.sh" --help)"
for flag in --arches --force --install-service --verify --help; do
  t_assert_contains "${out}" "${flag}"
done
t_assert_eq "0" "$(t_rc bash "${TESTS_DIR}/../setup-rootless-binfmt.sh" --help)"
t_assert_eq "0" "$(printf '%s' "${out}" | grep -c '^ARCHES=')"

t_case "Renovate help keeps its usage and exit-status contract"
out="$(bash "${TESTS_DIR}/../renovate-local.sh" --help)"
t_assert_contains "${out}" --apply
t_assert_contains "${out}" --managers
t_assert_contains "${out}" '130/143/129/141'

t_case "the agentic template keeps its help independently of header length"
eval "$(t_fn_src "${TESTS_DIR}/../../../shared/agentic-loop/templates/Run-AgenticLoop.sh" _agentic_template_usage)"
out="$(_agentic_template_usage)"
t_assert_contains "${out}" --planner-only
t_assert_contains "${out}" --executor-only
t_assert_contains "${out}" --max-iterations

t_summary
