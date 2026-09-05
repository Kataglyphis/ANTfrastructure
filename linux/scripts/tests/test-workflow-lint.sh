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

# _root <clean|broken>: a consumer checkout with one workflow of that shape.
_root() {
  local d; d="$(mktemp -d "${_work}/root.XXXXXX")"
  mkdir -p "${d}/.github/workflows"
  git -C "${d}" init -q   # actionlint resolves a project from the enclosing repo
  {
    printf 'name: ci\non: push\njobs:\n  build:\n    runs-on: ubuntu-latest\n    steps:\n'
    if [ "$1" = broken ]; then
      printf '      - run: echo "${{ github.no_such_property }}"\n'
    else
      printf '      - run: echo hello\n'
    fi
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

t_summary
