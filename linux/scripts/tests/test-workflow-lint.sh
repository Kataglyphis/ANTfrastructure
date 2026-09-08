#!/usr/bin/env bash
# Tests for lint-workflows.sh. Its own header names the hazard: "a lint gate that
# checks nothing still reports green". Two ways that happens here -- linting the
# WRONG tree (the consumer-root argument exists because a submodule checkout puts
# this script inside the consumer), and running an UNPINNED binary. Both are
# driven against the real actionlint, plus the refusals that keep the pin honest.
# docs/code-quality-tooling.md#workflow-lint-workflow-lint
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SCRIPTS="${TESTS_DIR}/.."
GATE="${SCRIPTS}/lint-workflows.sh"
PIN="$(sed -n 's/^ACTIONLINT_VERSION=//p' "${SCRIPTS}/01-core/versions.env")"

_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT

# _root <clean|broken|shellonly>: a consumer checkout with one workflow of that
# shape. `shellonly` carries a defect NOTHING but the embedded shellcheck pass
# of actionlint can see: SC1010, `[ ... ] then` with no separator. The YAML is
# valid, the expressions are valid, the step is valid -- so a green verdict on
# this fixture means the shell half of the gate did not run.
_root() {
  local d; d="$(mktemp -d "${_work}/root.XXXXXX")"
  mkdir -p "${d}/.github/workflows"
  git -C "${d}" init -q   # actionlint resolves a project from the enclosing repo
  {
    printf 'name: ci\non: push\njobs:\n  build:\n    runs-on: ubuntu-latest\n    steps:\n'
    case "$1" in
      broken)    printf '      - run: echo "${{ github.no_such_property }}"\n' ;;
      shellonly) printf '      - run: |\n          if [ "x" = "y" ] then\n            echo hi\n          fi\n' ;;
      *)         printf '      - run: echo hello\n' ;;
    esac
  } > "${d}/.github/workflows/ci.yml"
  printf '%s' "${d}"
}

t_case "a clean consumer checkout passes, and says which tree it linted"
clean="$(_root clean)"
_out="$(t_out bash "${GATE}" "${clean}")"
t_assert_eq "0" "$(t_rc bash "${GATE}" "${clean}")" \
  "the gate must be able to be green, or the red below proves only that it is broken"
t_assert_contains "${_out}" "linting workflows under ${clean}"
t_assert_contains "${_out}" "WORKFLOW LINT OK"

t_case "a real actionlint finding FAILS the gate"
broken="$(_root broken)"
_out="$(t_out bash "${GATE}" "${broken}")"
t_assert_eq "1" "$(t_rc bash "${GATE}" "${broken}")" "printing findings and exiting 0 is the whole hazard"
t_assert_contains "${_out}" "WORKFLOW LINT FAILED"
t_assert_contains "${_out}" "no_such_property" "the finding itself has to reach the log to be actionable"

t_case "the root argument decides WHICH tree is linted"
# A submodule checkout puts this script inside the consumer, where the default
# root resolves to ContainerHub. The two verdicts must follow the ARGUMENT: the
# broken checkout red, a clean sibling green while the broken one still exists.
t_assert_eq "1" "$(t_rc bash "${GATE}" "${broken}")"
t_assert_eq "0" "$(t_rc bash "${GATE}" "${clean}")" \
  "a gate that ignored its argument would give both checkouts the same verdict"
t_assert_contains "$(t_out bash "${GATE}" "${broken}")" "linting workflows under ${broken}" \
  "the banner must name the root it was handed"

t_case "a root that does not exist refuses, it does not fall back to this repo"
t_assert_eq "1" "$(t_rc bash "${GATE}" "${_work}/no-such-checkout")" \
  "falling back would lint a clean tree and report OK for a checkout nobody looked at"

t_case "the actionlint it runs is the pinned version"
t_assert_contains "$(t_out bash "${GATE}" "${clean}")" "actionlint (${PIN})" \
  "a lint verdict nobody can reproduce is not a gate"

# --- the bootstrap refusals: an unpinned binary must never run ----------------
# The gate resolves its pin from the versions.env beside ITSELF, so a throwaway
# copy at the real depth is what lets these be driven without a network.

_pin_tree() {  # <versions.env body>
  local d; d="$(mktemp -d "${_work}/pin.XXXXXX")"
  install -D -m 0755 "${GATE}" "${d}/linux/scripts/lint-workflows.sh"
  install -D -m 0644 "${SCRIPTS}/01-core/load-versions-env.sh" \
    "${d}/linux/scripts/01-core/load-versions-env.sh"
  install -D -m 0644 "${SCRIPTS}/01-core/downloads.sh" "${d}/linux/scripts/01-core/downloads.sh"
  printf '%s\n' "$1" > "${d}/linux/scripts/01-core/versions.env"
  mkdir -p "${d}/.github/workflows"
  git -C "${d}" init -q
  printf '%s' "${d}"
}

# A PATH with no actionlint on it and an empty cache dir, so the bootstrap is forced.
_no_tool() {
  local d="$1"
  PATH="/usr/bin:/bin" ACTIONLINT_CACHE_DIR="${_work}/empty-cache" \
    bash "${d}/linux/scripts/lint-workflows.sh" "${d}"
}

t_case "no ACTIONLINT_VERSION: the gate errors instead of linting with whatever it finds"
d="$(_pin_tree 'SOMETHING_ELSE=1')"
t_assert_eq "1" "$(t_rc _no_tool "${d}")"
t_assert_contains "$(t_out _no_tool "${d}")" "ACTIONLINT_VERSION is not set"

t_case "a pinned version with no pinned SHA256 is refused"
# Downloading a release nobody checksummed is how a lint gate starts running a
# binary the repo never chose.
d="$(_pin_tree "ACTIONLINT_VERSION=${PIN}")"
t_assert_eq "1" "$(t_rc _no_tool "${d}")"
t_assert_contains "$(t_out _no_tool "${d}")" "No pinned actionlint SHA256"

# --- the SHELL half of the gate ----------------------------------------------
# actionlint embeds a shellcheck pass over every `run:` block and reaches it by
# exec'ing the command name. With that name absent it DISABLES the rule and says
# nothing at normal verbosity -- so the gate printed WORKFLOW LINT OK over
# workflows whose shell nothing had read. These cases are the two halves of the
# fix: the rule is on, and a gate that cannot switch it on refuses to grade.

t_case "a run: block defect only shellcheck can see FAILS the gate"
shellonly="$(_root shellonly)"
_out="$(t_out bash "${GATE}" "${shellonly}")"
t_assert_eq "1" "$(t_rc bash "${GATE}" "${shellonly}")" \
  "the YAML is valid and the expressions are valid: a green verdict here means no run: block was read as shell"
t_assert_contains "${_out}" "shellcheck reported issue" \
  "the finding has to reach the log, not just the exit code"
t_assert_contains "${_out}" "SC1010"

t_case "the gate names the shellcheck it resolved, so the resolution is not a claim"
t_assert_contains "$(t_out bash "${GATE}" "${clean}")" "shellcheck for run: blocks ("

# A tree at the real depth again, this time varying the ACCESSOR the gate
# resolves shellcheck through. Nothing else can drive "shellcheck could not be
# resolved" without unpinning the host that runs this suite. The real pins and
# the CI-image-ref half are copied in so a refusal below is about shellcheck and
# nothing else.
_sc_tree() {  # <lint-shell.sh body>
  local d; d="$(_pin_tree "$(cat "${SCRIPTS}/01-core/versions.env")")"
  install -D -m 0644 "${SCRIPTS}/verify_ci_image_refs.py" \
    "${d}/linux/scripts/verify_ci_image_refs.py"
  printf '#!/usr/bin/env bash\n%s\n' "$1" > "${d}/linux/scripts/lint-shell.sh"
  chmod +x "${d}/linux/scripts/lint-shell.sh"
  printf 'name: ci\non: push\njobs:\n  build:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo hello\n' \
    > "${d}/.github/workflows/ci.yml"
  printf '%s' "${d}"
}
_sc_run() { bash "$1/linux/scripts/lint-workflows.sh" "$1"; }

t_case "the fixture itself is sound: with the REAL accessor this tree lints green"
# Without this the two refusals below could both be passing for the wrong reason
# (a broken fixture), which is the shape this repo keeps finding.
d="$(_sc_tree "exec bash '${SCRIPTS}/lint-shell.sh' \"\$@\"")"
t_assert_contains "$(t_out _sc_run "${d}")" "shellcheck for run: blocks ("
t_assert_eq "0" "$(t_rc _sc_run "${d}")" \
  "actionlint runs, shellcheck resolves, and the CI-image-ref half is satisfied"

t_case "shellcheck that cannot be resolved FAILS the gate, it does not lint half a gate"
d="$(_sc_tree 'exit 1')"
t_assert_eq "1" "$(t_rc _sc_run "${d}")" \
  "linting workflows with the shellcheck rule off is the defect, not a degraded mode"
t_assert_contains "$(t_out _sc_run "${d}")" "shellcheck could not be resolved"

t_case "a resolved binary that reports nothing also fails: the rule must actually FIRE"
# --print-bin answers with a real, correctly NAMED, executable shellcheck that
# happens to find nothing -- the shape of every way the rule can be present and
# useless (a stub on PATH, an unusable build, a platform where actionlint's own
# name lookup misses the file bash just found). Every precondition passes here;
# only the planted-SC1010 self-test can tell it from a working gate.
_fake="${_work}/fake-sc"
mkdir -p "${_fake}"
printf '#!/usr/bin/env bash\nexit 0\n' > "${_fake}/shellcheck"
chmod +x "${_fake}/shellcheck"
d="$(_sc_tree "echo '${_fake}/shellcheck'")"
# System tools only, so the ACCESSOR's answer is the only shellcheck in play:
# CI's runner carries one on PATH, and it would answer actionlint's name lookup
# behind the stub and make this case pass while proving nothing.
_sc_run_isolated() { PATH="/usr/bin:/bin" bash "$1/linux/scripts/lint-workflows.sh" "$1"; }
t_assert_eq "1" "$(t_rc _sc_run_isolated "${d}")" \
  "the gate must not report a verdict it could not have reached"
_out="$(t_out _sc_run_isolated "${d}")"
t_assert_contains "${_out}" "did not report the planted SC1010"
# The precondition is satisfied here on purpose: a refusal from the NAME check
# instead would leave the self-test unproven, and the mutation gate said so.
t_assert_fails grep -q -F -e 'does not resolve on PATH' <<<"${_out}"

t_summary
