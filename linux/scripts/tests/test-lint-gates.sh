#!/usr/bin/env bash
# Tests for run-lint-gates.sh and 01-core/gates.sh. Everything here is about the
# one failure mode a lint aggregator actually has: reporting GREEN over a tree it
# never looked at. So the assertions are on the scope construction, the vacuity
# guards and the accumulate-then-re-raise contract - not on shellcheck's or
# gitleaks' own verdicts, which their own suites already own and which would
# make this suite need three network bootstraps to say anything.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SCRIPTS="${TESTS_DIR}/.."
GATE="${SCRIPTS}/run-lint-gates.sh"

_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT

# A consumer-shaped checkout: first-party tree, a vendored third_party/ subtree,
# and one first-party file sitting directly inside third_party/.
_consumer() {
  local d; d="$(mktemp -d "${_work}/root.XXXXXX")"
  mkdir -p "${d}/scripts/lib" "${d}/third_party/Vendored/deep"
  printf '#!/usr/bin/env bash\ntrue\n' > "${d}/scripts/a.sh"
  printf '#!/usr/bin/env bash\ntrue\n' > "${d}/scripts/lib/b.sh"
  printf '#!/usr/bin/env bash\ntrue\n' > "${d}/third_party/Vendored/deep/c.sh"
  printf 'x\n' > "${d}/README.md"
  printf 'x\n' > "${d}/third_party/CMakeLists.txt"
  mkdir -p "${d}/aß-dir"; printf '#!/usr/bin/env bash\ntrue\n' > "${d}/aß-dir/d.sh"
  git -C "${d}" init -q
  git -C "${d}" add -A >/dev/null 2>&1
  printf '%s' "${d}"
}

t_case "the consumer root is mandatory and never inferred"
t_assert_eq "2" "$(t_rc bash "${GATE}")" \
  "a BASH_SOURCE-derived root resolves inside the submodule and grades ContainerHub"
t_assert_contains "$(t_out bash "${GATE}")" "consumer repo root is required"
t_assert_eq "2" "$(t_rc bash "${GATE}" "${_work}/does-not-exist")"
t_assert_eq "2" "$(t_rc bash "${GATE}" "${_work}")" \
  "a non-git root cannot produce a scope; it must say so rather than scan nothing"
t_assert_eq "2" "$(t_rc bash "${GATE}" "$(_consumer)" --nonsense)" \
  "an unknown flag must not be swallowed into a default scope"

# Sourced, not executed: the scope functions are what this suite grades, and the
# three gate binaries they eventually call each need a network bootstrap.
# shellcheck source=../run-lint-gates.sh
source "${GATE}"

_root="$(_consumer)"
_lint_gates_parse_args "${_root}"

t_case "the excluded prefix hides the vendored subtree, not the top-level file"
t_assert_eq "0" "$(t_rc _lint_gates_excluded third_party/Vendored/deep/c.sh)"
t_assert_eq "0" "$(t_rc _lint_gates_excluded third_party/CMakeLists.txt)"
t_assert_eq "1" "$(t_rc _lint_gates_excluded scripts/a.sh)"
t_assert_eq "1" "$(t_rc _lint_gates_excluded README.md)" \
  "a top-level file is never a prefix match, whatever it is called"

t_case "the shell list recurses and drops the vendored tree"
_files="$(_lint_gates_shell 2>/dev/null | sed -n 's/^  //p' | sort)"
t_assert_contains "${_files}" "scripts/a.sh"
t_assert_contains "${_files}" "scripts/lib/b.sh" \
  "a non-recursive glob covered scripts/*.sh only and still read as complete"
t_assert_contains "${_files}" "aß-dir/d.sh" \
  "git QUOTES a non-ASCII path unless -z is used, and the quoted string names nothing"
t_assert_eq "" "$(printf '%s\n' "${_files}" | grep 'third_party' || true)"

t_case "the secret scope keeps the consumer's own file inside the vendored dir"
_scope="$(_lint_gates_secret_scope | sort)"
t_assert_contains "${_scope}" "third_party/CMakeLists.txt" \
  "dropping the whole prefix excluded the consumer's own file with the vendored tree"
t_assert_contains "${_scope}" "scripts"
t_assert_contains "${_scope}" "README.md"
t_assert_eq "" "$(printf '%s\n' "${_scope}" | grep -x 'third_party' || true)" \
  "the vendored directory itself must never be handed to gitleaks"

t_case "an empty shell list FAILS instead of falling back to ContainerHub's own tree"
_empty="$(mktemp -d "${_work}/empty.XXXXXX")"
printf 'x\n' > "${_empty}/README.md"
git -C "${_empty}" init -q; git -C "${_empty}" add -A >/dev/null 2>&1
_lint_gates_parse_args "${_empty}"
t_assert_eq "1" "$(t_rc _lint_gates_shell)" \
  "lint-shell.sh with zero file arguments lints ContainerHub and exits 0"

t_case "gates.sh: every gate runs, and the verdict is raised once at the end"
gate_reset "T"
run_gate "first" false
run_gate "second" true
run_gate "third" false
t_assert_eq "3" "${_GATE_RAN}" "stopping at the first failure costs one push per finding"
t_assert_eq "first third" "${_GATE_FAILURES[*]}"
t_assert_eq "1" "$(t_rc assert_gates)"

t_case "gates.sh: a batch in which NOTHING ran is not green"
gate_reset "T"
t_assert_eq "1" "$(t_rc assert_gates)" \
  "an aggregator that graded nothing reporting OK is the hazard, not an edge case"
t_assert_contains "$(t_out assert_gates)" "no gate ran"

t_case "gates.sh: a clean batch is green, and a missing command is a caller bug"
gate_reset "T"
run_gate "only" true
t_assert_eq "0" "$(t_rc assert_gates)" \
  "it must be able to be green, or the reds above prove only that it is broken"
t_assert_eq "2" "$(t_rc run_gate "nocmd")"

t_summary
