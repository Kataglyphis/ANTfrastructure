#!/usr/bin/env bash
# The sha-pin workflow convention; not covered: what a pinned commit contains or actions fetched by run: blocks.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SCRIPTS="${TESTS_DIR}/.."
CONV="${SCRIPTS}/verify_workflow_conventions.py"
_PY="${PREFLIGHT_PYTHON:-python3}"
SHA40=3d3c42e5aac5ba805825da76410c181273ba90b1
unset WORKFLOW_CONVENTIONS_GATE

_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT

# _tree <workflow body>: an OrchestrANT origin, since the gate keys every verdict on a declared repository.
_tree() {
  local d; d="$(mktemp -d "${_work}/tree.XXXXXX")"
  mkdir -p "${d}/.github/workflows"
  git -C "${d}" init -q
  git -C "${d}" remote add origin https://github.com/Kataglyphis/OrchestrANT.git
  printf '%s\n' "$1" > "${d}/.github/workflows/ci.yml"
  printf '%s' "${d}"
}

_step() {
  printf 'name: ci\non: push\npermissions:\n  contents: read\njobs:\n  build:\n'
  printf '    runs-on: ubuntu-24.04\n    timeout-minutes: 5\n    steps:\n      - uses: %s\n' "$1"
}

_conv() { "${_PY}" "${CONV}" "$1"; }
_armed() { WORKFLOW_CONVENTIONS_GATE=sha-pin _conv "$1"; }

t_case "actions/checkout@v7 FAILS once sha-pin is armed"
tagged="$(_tree "$(_step actions/checkout@v7)")"
t_assert_eq "1" "$(t_rc _armed "${tagged}")" "a moved tag runs code nobody reviewed"
t_assert_contains "$(t_out _armed "${tagged}")" 'FAIL: .github/workflows/ci.yml:10 [sha-pin] `uses: actions/checkout@v7`'

t_case "unarmed, the finding is advisory and needs no census row"
t_assert_eq "0" "$(t_rc _conv "${tagged}")" "consumers that never armed it keep their verdict"
t_assert_contains "$(t_out _conv "${tagged}")" "ADVISORY .github/workflows/ci.yml:10 [sha-pin]"

t_case "a 40-hex SHA, a local action and the hub at develop pass when armed"
for ref in "actions/checkout@${SHA40}" ./.github/actions/local \
    Kataglyphis/ANTfrastructure/.github/actions/run-in-linux-container@develop; do
  t_assert_eq "0" "$(t_rc _armed "$(_tree "$(_step "${ref}")")")" "${ref} is pinned or exempt"
done

t_case "a short SHA, another family repo at develop and a tagged image fail when armed"
for ref in actions/checkout@3d3c42e Kataglyphis/DocumANTation/.github/actions/x@develop docker://alpine:3.22; do
  t_assert_eq "1" "$(t_rc _armed "$(_tree "$(_step "${ref}")")")" "${ref} is not a commit pin"
done

t_case "a job-level reusable-workflow call is graded"
called="$(_tree 'name: ci
on: push
permissions:
  contents: read
jobs:
  call:
    uses: octo/reusable/.github/workflows/x.yml@main')"
t_assert_eq "1" "$(t_rc _armed "${called}")"
t_assert_contains "$(t_out _armed "${called}")" "ci.yml:7 [sha-pin]"

t_case "composite actions are graded too"
composite="$(_tree "$(_step "actions/checkout@${SHA40}")")"
mkdir -p "${composite}/.github/actions/probe"
printf 'name: probe\nruns:\n  using: composite\n  steps:\n    - uses: actions/setup-python@v6\n' \
  > "${composite}/.github/actions/probe/action.yml"
t_assert_eq "1" "$(t_rc _armed "${composite}")"
t_assert_contains "$(t_out _armed "${composite}")" ".github/actions/probe/action.yml:5 [sha-pin]"

t_summary
