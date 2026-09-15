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
  "a BASH_SOURCE-derived root resolves inside the submodule and grades ANTfrastructure"
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

t_case "an empty shell list FAILS instead of falling back to ANTfrastructure's own tree"
_empty="$(mktemp -d "${_work}/empty.XXXXXX")"
printf 'x\n' > "${_empty}/README.md"
git -C "${_empty}" init -q; git -C "${_empty}" add -A >/dev/null 2>&1
_lint_gates_parse_args "${_empty}"
t_assert_eq "1" "$(t_rc _lint_gates_shell)" \
  "lint-shell.sh with zero file arguments lints ANTfrastructure and exits 0"

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

# --- the shared-config gate --------------------------------------------------
# What is pinned is the one thing this gate can get wrong that nothing else
# would notice: passing while comparing NOTHING. The verdict logic itself
# belongs to test-shared-config-sync.sh; here it only has to be reached, and it
# must not be reachable by accident.
_HUB="$(cd "${SCRIPTS}/../.." && pwd)"

_declaring() {  # _declaring <manifest-body> -> a git root carrying a faithful copy
  local d; d="$(mktemp -d "${_work}/decl.XXXXXX")"
  cp "${_HUB}/shared/config/.clang-format" "${d}/.clang-format"
  printf '%s\n' "$1" > "${d}/.antfrastructure-shared.manifest"
  git -C "${d}" init -q; git -C "${d}" add -A >/dev/null 2>&1
  printf '%s' "${d}"
}

t_case "no manifest is a FAILURE, not a skip"
_lint_gates_parse_args "$(_consumer)"
t_assert_eq "1" "$(t_rc _lint_gates_shared_config)" \
  "the legacy fallback grades five root names the repo may never have taken; a green gate over nothing is what made this mechanism inert in the first place"
_out="$(t_out _lint_gates_shared_config)"
t_assert_contains "${_out}" "no .antfrastructure-shared.manifest"
t_assert_contains "${_out}" "antfrastructure-sh" \
  "the failure must spell the declaration, or it only says no"

t_case "a declared, faithful copy passes"
_lint_gates_parse_args "$(_declaring clang-format)"
t_assert_eq "0" "$(t_rc _lint_gates_shared_config)" \
  "it must be able to be green, or the reds prove only that it is broken"

t_case "a declared copy that drifted FAILS, and is named"
_drift="$(_declaring clang-format)"
printf '# an edit the consumer made locally\n' >> "${_drift}/.clang-format"
_lint_gates_parse_args "${_drift}"
t_assert_eq "1" "$(t_rc _lint_gates_shared_config)"
t_assert_contains "$(t_out _lint_gates_shared_config)" "DRIFTED .clang-format"

t_case "the gate is registered, so it cannot be defined and never called"
t_assert_contains "$(cat "${GATE}")" 'run_gate "shared-config drift" _lint_gates_shared_config'

t_case "gates.sh: a clean batch is green, and a missing command is a caller bug"
gate_reset "T"
run_gate "only" true
t_assert_eq "0" "$(t_rc assert_gates)" \
  "it must be able to be green, or the reds above prove only that it is broken"
t_assert_eq "2" "$(t_rc run_gate "nocmd")"

# --- the third bucket: a gate that COULD NOT run -----------------------------
# A missing tool is neither a pass nor a failure, and the two ways to pretend
# otherwise are both lies this file exists to prevent. So the assertions are
# that the record is KEPT, that keeping it is red until somebody asks for
# tolerance in writing, and that tolerance never reaches the other two buckets.
# docs/shared-script-libraries.md#gate-aggregation-01-coregatessh

t_case "gates.sh: gate_skip records the gate and its reason, and grades nothing"
gate_reset "T"
# t_out is a command SUBSTITUTION, so the record it makes dies with the
# subshell; the call that has to leave a mark on this shell is the bare one.
_skip_out="$(t_out gate_skip "clang-tidy" "not installed in this image")"
t_assert_contains "${_skip_out}" "SKIPPED"
t_assert_contains "${_skip_out}" "not installed in this image" \
  "a skip without its reason reads the same as a gate somebody quietly deleted"
gate_skip "clang-tidy" "not installed in this image" 2>/dev/null
t_assert_eq "clang-tidy" "${_GATE_SKIPPED[*]}"
t_assert_eq "0" "${_GATE_RAN}" \
  "counting a skip as a gate that RAN makes a batch of nothing but skips green"

t_case "gates.sh: the reason is optional, and gate_reset empties the bucket"
gate_reset "T"
gate_skip "bare" 2>/dev/null
t_assert_eq "bare" "${_GATE_SKIPPED[*]}"
gate_reset "T"
t_assert_eq "0" "${#_GATE_SKIPPED[@]}" \
  "a skip surviving gate_reset reds the NEXT batch over a tool it never wanted"

t_case "gates.sh: a skip is RED by default"
gate_reset "T"
run_gate "ran" true >/dev/null
gate_skip "missing-tool" "no such binary" 2>/dev/null
t_assert_eq "1" "$(t_rc assert_gates)" \
  "a silently tolerated skip is the 'allowed to fail' default the fleet rule forbids"
_skip_verdict="$(t_out assert_gates)"
t_assert_contains "${_skip_verdict}" "missing-tool"
t_assert_contains "${_skip_verdict}" "--tolerate-skips" \
  "the red must name the flag, or the only visible way out of it is to delete the gate"

t_case "gates.sh: --tolerate-skips is what makes that same batch green"
t_assert_eq "0" "$(t_rc assert_gates --tolerate-skips)" \
  "tolerance must be reachable, or the red above proves only that it is broken"
t_assert_contains "$(t_out assert_gates --tolerate-skips)" "1 skipped" \
  "a tolerated skip is still printed: tolerated is not the same as invisible"

t_case "gates.sh: a batch of ONLY skips is red even WITH --tolerate-skips"
gate_reset "T"
gate_skip "one" "absent" 2>/dev/null
gate_skip "two" "absent" 2>/dev/null
t_assert_eq "1" "$(t_rc assert_gates --tolerate-skips)" \
  "nothing was graded, so there is no result to tolerate - the vacuity rule outranks the flag"
t_assert_contains "$(t_out assert_gates --tolerate-skips)" "no gate ran"

t_case "gates.sh: --tolerate-skips does not tolerate a FAILURE sharing the batch"
gate_reset "T"
run_gate "broken" false >/dev/null 2>&1
gate_skip "absent" "no binary" 2>/dev/null
t_assert_eq "1" "$(t_rc assert_gates --tolerate-skips)"
t_assert_contains "$(t_out assert_gates --tolerate-skips)" "T FAILED (1 of 1): broken" \
  "one flag covering both buckets would make a missing tool a way to pass a failing one"

t_case "gates.sh: an unknown assert_gates flag is a caller bug, not a verdict"
gate_reset "T"
run_gate "ran" true >/dev/null
t_assert_eq "2" "$(t_rc assert_gates --tolerate-skip)" \
  "a near-miss flag swallowed as 'no flag given' silently re-arms the default it was meant to lift"
t_assert_eq "2" "$(t_rc assert_gates --fail-on-skip)" \
  "--fail-on-skip is the OLD spelling and is now the DEFAULT; accepting it would green batches it used to red"
t_assert_contains "$(t_out assert_gates --nonsense)" "unknown argument"

# --- run_gate contains a helper that reports failure with exit ---------------
# The bug the subshell fixes. Upstream check helpers report failure with err(),
# which is `exit 1`; run as a bare "$@" that exit unwinds the DRIVER, so the
# gates after it never run and assert_gates never prints a verdict - "stop at
# the first failure" arriving through the back door. Graded by running ONE
# driver against the shipped file and against a copy with the subshell removed:
# the copy has to die, or the shipped file's pass proves nothing.
_GATES="${SCRIPTS}/01-core/gates.sh"
_subshell_hits() { grep -c '( "\$@" )' "$1" || true; }

_driver="${_work}/exiting-gate-driver.sh"
cat > "${_driver}" <<'DRIVER'
set -u
source "$1"
_erring() { echo "helper says no" >&2; exit 1; }
gate_reset "D"
run_gate "before" true
run_gate "erring" _erring
run_gate "after"  true
assert_gates
echo "VERDICT-REACHED rc=$?"
DRIVER

t_case "gates.sh: a gate whose command exits 1 does not kill the driver"
t_assert_eq "1" "$(_subshell_hits "${_GATES}")" \
  "the subshell this case is about is gone from the shipped file"
_shipped_out="$(bash "${_driver}" "${_GATES}" 2>&1)"
t_assert_contains "${_shipped_out}" "== after ==" \
  "the exit unwound the driver, so every gate after the erring one never ran"
t_assert_contains "${_shipped_out}" "D FAILED (1 of 3): erring" \
  "assert_gates has to be REACHED, and still name the one gate that failed"
t_assert_contains "${_shipped_out}" "VERDICT-REACHED rc=1"

t_case "gates.sh: and without the subshell that same driver dies mid-batch"
_bare="${_work}/gates-no-subshell.sh"
sed 's/^  ( "\$@" ) || status=\$?$/  "$@" || status=$?/' "${_GATES}" > "${_bare}"
t_assert_eq "0" "$(_subshell_hits "${_bare}")" \
  "the control copy still has the subshell, so this whole case would pass vacuously"
_bare_out="$(bash "${_driver}" "${_bare}" 2>&1)"
t_assert_eq "1" "$(t_rc bash "${_driver}" "${_bare}")"
t_assert_eq "" "$(printf '%s\n' "${_bare_out}" | grep 'VERDICT-REACHED' || true)" \
  "the control must die BEFORE its verdict; if it survives, the case above is not about the subshell"
t_assert_eq "" "$(printf '%s\n' "${_bare_out}" | grep '== after ==' || true)" \
  "and it must take the remaining gates with it - that loss is the cost being pinned"

# --- the ratchet gates, opt-in -----------------------------------------------
# Eight --root gates exist for consumers and no consumer ran them, because the
# aggregator never called them. They are now behind --ratchets: registered only
# when asked, because a tree with no freeze files is red on its first run.
t_case "--ratchets is accepted and sets the flag; no flag, no ratchet"
_LINT_GATES_RATCHETS=0
_lint_gates_parse_args "$(_consumer)" --ratchets
t_assert_eq "1" "${_LINT_GATES_RATCHETS}"
_LINT_GATES_RATCHETS=0
_lint_gates_parse_args "$(_consumer)"
t_assert_eq "0" "${_LINT_GATES_RATCHETS}"

t_case "the ratchet gate is registered, and only behind the flag"
t_assert_contains "$(cat "${GATE}")" 'run_gate "ratchets" _lint_gates_ratchet'
t_assert_eq "0" "$(grep -c '^  run_gate "ratchets"' "${GATE}")" \
  "an unconditional registration reddens every consumer that has not seeded its freeze files"

t_case "every gate the ratchet step names ships beside the aggregator"
for _ratchet in "${_LINT_GATES_RATCHET_GATES[@]}"; do
  t_assert_eq "0" "$(t_rc test -f "${SCRIPTS}/${_ratchet}.py")" "${_ratchet}.py is named by the step and must exist"
  t_assert_contains "$(grep -c -- '--root' "${SCRIPTS}/${_ratchet}.py")" "" \
    "${_ratchet}.py must take --root, or the step grades the hub over a consumer"
  t_assert_eq "1" "$(grep -q -- '"--root"' "${SCRIPTS}/${_ratchet}.py" && echo 1 || echo 0)" \
    "${_ratchet}.py must take --root, or the step grades the hub over a consumer"
done

# Rule 2 of the scan-root contract: an empty scan is a decision, never a default,
# and the decision belongs to whoever pointed the gate at the tree. Eight gates
# each reporting green over nothing is the vacuity this whole suite is about, so
# the aggregator answers ONCE, with `allow`, and says so out loud.
t_case "an empty *.sh scan is allowed once by the aggregator, not eight times in silence"
t_assert_contains "$(cat "${GATE}")" 'gate_scope.assert_non_empty(RELS, ROOT, ["*.sh"], "allow", "ratchets")' \
  "the one owner of rule 2 must be asked, not re-implemented in bash"
t_assert_contains "$(cat "${GATE}")" '_lint_gates_ratchet_scope' \
  "the ratchet step must consult the scope before running any gate"
_noshell="$(mktemp -d "${_work}/noshell.XXXXXX")"
printf 'x\n' > "${_noshell}/README.md"
git -C "${_noshell}" init -q
t_git_commit "${_noshell}"
_LINT_GATES_PY=""
if _lint_gates_interpreter >/dev/null 2>&1; then
  _LINT_GATES_ROOT="${_noshell}"
  t_assert_eq "1" "$(t_rc _lint_gates_ratchet_scope)" \
    "no tracked shell is 'nothing to grade', which is rc 1, not a refusal"
  t_assert_contains "$(t_out _lint_gates_ratchet_scope)" "nothing to grade" \
    "silence over an empty scope is what rule 2 exists to forbid"
  t_assert_eq "0" "$(t_rc _lint_gates_ratchet)" \
    "the step is green, and no gate ran"
  _LINT_GATES_ROOT="$(_consumer)"
  t_assert_eq "0" "$(t_rc _lint_gates_ratchet_scope)" \
    "a consumer that HAS shell must still be graded"
  _LINT_GATES_ROOT="${_work}"
  t_assert_eq "2" "$(t_rc _lint_gates_ratchet_scope)" \
    "a root that is not a checkout is a broken call, not an empty one"
fi

t_case "the Python gates run under PREFLIGHT_PYTHON, and a dead interpreter is named"
_LINT_GATES_PY=""
t_assert_eq "1" "$(PREFLIGHT_PYTHON=/nonexistent/python t_rc _lint_gates_interpreter)"
t_assert_contains "$(PREFLIGHT_PYTHON=/nonexistent/python t_out _lint_gates_interpreter)" "PREFLIGHT_PYTHON" \
  "the failure must name the knob that fixes it"

t_case "a working PREFLIGHT_PYTHON is published verbatim, a command line included"
# The probe's own hint is PREFLIGHT_PYTHON="uv run --no-project python", so a
# multi-word value must pass the probe and reach the call sites unquoted.
_fakepy="$(mktemp -d)/fakepy"
printf '#!/bin/sh\nexit 0\n' > "${_fakepy}"; chmod +x "${_fakepy}"
_LINT_GATES_PY=""
PREFLIGHT_PYTHON="${_fakepy}" _lint_gates_interpreter
t_assert_eq "${_fakepy}" "${_LINT_GATES_PY}" "single-word interpreter published"
_LINT_GATES_PY=""
PREFLIGHT_PYTHON="${_fakepy} --flag" _lint_gates_interpreter
t_assert_eq "${_fakepy} --flag" "${_LINT_GATES_PY}" "multi-word interpreter published as one command line"
t_assert_eq "0" "$(grep -c '"\${_LINT_GATES_PY}"' "${GATE}")" \
  "the interpreter must be expanded UNQUOTED at every call site, or the hint the probe gives cannot work"

t_case "the probe did not shadow the ruff gate: _lint_gates_python is defined once and registered as ruff"
t_assert_eq "1" "$(grep -c '^_lint_gates_python() {' "${GATE}")" "one definition, the ruff scope"
t_assert_contains "$(cat "${GATE}")" 'run_gate "ruff" _lint_gates_python'
t_assert_eq "1" "$(grep -c '^_lint_gates_interpreter() {' "${GATE}")" "the probe has its own name"

t_summary
