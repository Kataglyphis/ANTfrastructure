#!/usr/bin/env bash
# verify_workflow_conventions.py's run-filter check: GitHub's filter grammar over workflow_run names, in a fixture tree.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
_PY="${PREFLIGHT_PYTHON:-python3}"
# _findings <workflow_run filter, YAML-quoted>: the run-filter findings for a tree with a "Linux x64 · build + test" lane.
_findings() {
  local d; d="$(t_mktemp -d)"
  mkdir -p "${d}/.github/workflows"
  printf 'name: Linux x64 · build + test\non: push\n' > "${d}/.github/workflows/lane.yml"
  printf 'on: push\n' > "${d}/.github/workflows/unnamed.yml"
  printf 'name: retry\non:\n  workflow_run:\n    workflows:\n      - %s\n    types: [completed]\n' "$1" \
    > "${d}/.github/workflows/retry.yml"
  PYTHONPATH="${TESTS_DIR}/.." "${_PY}" - "${d}" <<'PY'
import sys
from pathlib import Path

import verify_workflow_conventions as v

root = Path(sys.argv[1])
for rel, check, detail, _num, why in v.collect(root, v.yaml_files(root)):
    if check == "run-filter":
        print(why)
PY
}

t_case "an escaped plus matches the lane's literal name"
t_assert_eq "" "$(_findings "'Linux x64 · build \+ test'")" "an escaped '+' is the literal plus"

t_case "an unescaped plus repeats the space before it and never matches a literal plus"
t_assert_contains "$(_findings '"Linux x64 · build + test"')" "matches no workflow name"

t_case "a bracket with a space or angle brackets is no GitHub range: the phantom-run pattern"
t_assert_contains "$(_findings '"On request · [ci <lane>]"')" "is no valid GitHub filter pattern"

t_case "globs and a workflow known only by its path match"
t_assert_eq "" "$(_findings "'Linux * · build \+ test'")" "'*' spans any characters but '/'"
t_assert_eq "" "$(_findings '".github/workflows/unnamed.yml"')" "an unnamed workflow is called by its path"

t_case "a leading repeat operator repeats nothing"
t_assert_contains "$(_findings '"+x"')" "repeats nothing"

t_summary
