#!/usr/bin/env bash
# [root]: pinned actionlint with its shellcheck half, plus the image-ref and workflow-convention gates.
set -uo pipefail

SCRIPT_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LINT_ROOT="$(cd "${1:-${SCRIPT_REPO_ROOT}}" && pwd)" || exit 1
REPO_ROOT="${SCRIPT_REPO_ROOT}"
echo "== linting workflows under ${LINT_ROOT} =="
cd "${LINT_ROOT}" || exit 1

CORE_DIR="${REPO_ROOT}/linux/scripts/01-core"

err() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# shellcheck source=01-core/lint-tool-release.sh
source "${CORE_DIR}/lint-tool-release.sh"

actionlint_ensure() {
  lint_tool_ensure actionlint ACTIONLINT_BIN
}

# actionlint's shell half: without shellcheck on PATH it silently disables the rule.

# lint-shell.sh --print-bin owns the binary; its dir goes on PATH since actionlint looks up the name.
shellcheck_for_actionlint() {
  local bin dir named
  bin="$(bash "${REPO_ROOT}/linux/scripts/lint-shell.sh" --print-bin)" || bin=""
  [ -n "${bin}" ] && [ -x "${bin}" ] || err \
    "shellcheck could not be resolved through lint-shell.sh --print-bin. actionlint would disable its shellcheck rule and grade no run: block at all, so this gate refuses to report a verdict."
  dir="$(cd "$(dirname "${bin}")" && pwd)" \
    || err "the resolved shellcheck (${bin}) is not in a readable directory."
  PATH="${dir}:${PATH}"
  export PATH
  # Prove the name resolves here, where the error can say why, before actionlint drops the rule.
  named="$(command -v shellcheck)" || err \
    "shellcheck resolved to ${bin} but the NAME does not resolve on PATH after adding ${dir}; actionlint looks it up by name and would disable the rule."
  printf '== shellcheck for run: blocks (%s) ==\n' "$("${named}" --version | sed -n 's/^version: //p')"
}

# Proves the rule fires on a shell-only defect (SC1010); --verbose output interleaves too badly to parse.
shellcheck_rule_selftest() {
  local out
  out="$(printf 'name: probe\non: push\njobs:\n  j:\n    runs-on: ubuntu-24.04\n    steps:\n      - run: |\n          if [ "x" = "y" ] then\n            echo hi\n          fi\n' \
    | "${ACTIONLINT_BIN}" -stdin-filename shellcheck-selftest.yml - 2>&1)"
  case "${out}" in
    *"shellcheck reported issue"*) return 0 ;;
  esac
  printf '%s\n' "${out}" >&2
  err "actionlint did not report the planted SC1010 in a run: block, so its shellcheck rule is off and every run: block would be graded for YAML only. The verdict would be void; not reporting one."
}

actionlint_ensure
printf '== actionlint (%s) ==\n' "$("${ACTIONLINT_BIN}" --version | head -n1)"
shellcheck_for_actionlint
shellcheck_rule_selftest

FAILED=0
# The pinned actionlint predates ubuntu-26.04; reuse the hub label policy when a consumer has none.
ACTIONLINT_CONFIG=()
if [ ! -f .github/actionlint.yaml ] && [ ! -f .github/actionlint.yml ] \
    && [ -f "${REPO_ROOT}/.github/actionlint.yaml" ]; then
  ACTIONLINT_CONFIG=(-config-file "${REPO_ROOT}/.github/actionlint.yaml")
fi
"${ACTIONLINT_BIN}" "${ACTIONLINT_CONFIG[@]}" || FAILED=1

# This checkout's copy of the script, run against the handed tree.
# shellcheck source=01-core/python-probe.sh
source "${CORE_DIR}/python-probe.sh"
preflight_python_require lint-workflows.sh || exit 1
( cd "${REPO_ROOT}" && ${PREFLIGHT_PYTHON} linux/scripts/verify_ci_image_refs.py "${LINT_ROOT}" ) || FAILED=1

# Its workflow-conventions.allow comes from this repo too, so one table holds every consumer's deviations.
( cd "${REPO_ROOT}" && ${PREFLIGHT_PYTHON} linux/scripts/verify_workflow_conventions.py "${LINT_ROOT}" ) || FAILED=1

if [ "${FAILED}" -eq 0 ]; then
  printf 'WORKFLOW LINT OK\n'
else
  printf 'WORKFLOW LINT FAILED\n' >&2
  exit 1
fi
