#!/usr/bin/env bash
# verify_readme_length.py, in preflight and in run-lint-gates.sh: a root README.md over 100 lines fails. See docs/code-quality-tooling.md#readme-length-readme-length
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SCRIPTS="$(cd "${TESTS_DIR}/.." && pwd)"
GATE="${SCRIPTS}/verify_readme_length.py"
PY="${PREFLIGHT_PYTHON:-python3}"
_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT

# _repo <lines> [no-eol]: a git root whose README.md has that many lines; no-eol drops the last newline.
_repo() {
  local d i; d="$(mktemp -d "${_work}/repo.XXXXXX")"
  for ((i = 1; i <= $1; i++)); do printf 'line %d\n' "${i}"; done > "${d}/README.md"
  [ "${2-}" != no-eol ] || printf 'one more line' >> "${d}/README.md"
  git -C "${d}" init -q && git -C "${d}" -c core.autocrlf=false add -A
  printf '%s' "${d}"
}

_grade() { "${PY}" "${GATE}" --root "$1"; }

t_case "100 lines, badges included, is the limit and passes"
d="$(_repo 100)"
t_assert_eq 0 "$(t_rc _grade "${d}")" "the rule allows 100 lines"
t_assert_contains "$(t_out _grade "${d}")" "README.md is 100 lines"

t_case "101 lines fail, and the message names the rule and its page"
d="$(_repo 101)"
t_assert_eq 1 "$(t_rc _grade "${d}")" "one line over the limit fails"
t_assert_contains "$(t_out _grade "${d}")" "README.md is 101 lines"
t_assert_contains "$(t_out _grade "${d}")" "the README rule"
t_assert_contains "$(t_out _grade "${d}")" "docs/repository-family.md#the-readme-rule"

t_case "a last line without a newline still counts"
t_assert_eq 1 "$(t_rc _grade "$(_repo 100 no-eol)")" "100 lines plus an unterminated one is 101"

t_case "no README.md, or no git root, is not a pass"
d="$(mktemp -d "${_work}/bare.XXXXXX")"
printf 'x\n' > "${d}/other.md"
git -C "${d}" init -q
t_assert_eq 1 "$(t_rc _grade "${d}")" "every repository has a README; a missing one is not short"
t_assert_contains "$(t_out _grade "${d}")" "every repository has one" "a verdict, not a traceback"
t_assert_eq 2 "$(t_rc _grade "${_work}")" "a root that is no git checkout grades nothing"

t_case "run-lint-gates.sh grades the consumer's README with the same gate"
# shellcheck source=../run-lint-gates.sh
source "${SCRIPTS}/run-lint-gates.sh"
_lint_gates_parse_args "$(_repo 101)"
t_assert_eq 1 "$(t_rc _lint_gates_readme)" "a consumer README over the limit fails the aggregator"
_lint_gates_parse_args "$(_repo 60)"
t_assert_eq 0 "$(t_rc _lint_gates_readme)" "a short one passes"
t_assert_contains "$(cat "${SCRIPTS}/run-lint-gates.sh")" 'run_gate "README length" _lint_gates_readme'

t_summary
