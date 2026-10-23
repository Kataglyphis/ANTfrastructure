#!/usr/bin/env bash
# Fixture drivers cover shell ordering, capture and compiler-less inputs, not real builds or preflight tooling.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
source "${TESTS_DIR}/sourced-module-fixture.sh"
source "${TESTS_DIR}/test-workspace-fixture.sh"
source "${TESTS_DIR}/cmake-project-fixture.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
printf 'printf "import:%%s\\n" "$fixture_value"\nfixture_value=imported\n' > "$WORK/module.sh"

t_case "module setup, import and body retain their order"
actual="$(t_run_sourced_module "$WORK/module.sh" 'fixture_value=prepared' 'printf "body:%s" "$fixture_value"')"
t_assert_eq "$actual" $'import:prepared\nbody:imported'
t_case "module body remains isolated from its parent"
t_assert_rc 1 test "${fixture_value:-}" = imported
printf 'read -r fixture_input; printf "input:%%s" "$fixture_input"\n' > "$WORK/input.sh"
t_case "sourced modules retain caller stdin"
t_assert_eq 'input:receipt' "$(printf 'receipt\n' | t_run_sourced_module "$WORK/input.sh" '' ':')"
printf 'return 37\n' > "$WORK/failing.sh"
t_case "failed imports propagate their status without running the body"
t_assert_rc 37 t_run_sourced_module "$WORK/failing.sh" '' 'exit 0'
t_case "setup pipelines retain pipefail"
t_assert_rc 1 t_run_sourced_module "$WORK/module.sh" 'fixture_value=prepared; false | true' 'exit 0'

cat > "$WORK/gates.sh" <<'GATES'
fixture_gate() {
  printf 'cwd:%s' "${PWD##*/}"
  printf ':stderr' >&2
  return 23
}
GATES
mkdir "$WORK/consumer"
preflight_result="$(bash -c '
  source "$1/test-harness.sh"
  source "$1/preflight-gate-fixture.sh"
  declare workspace
  preflight_gate_fixture_init workspace fixture_gate "$2/gates.sh" || exit
  preflight_gate_fixture_run output rc "$2/consumer"
  printf "%s|%s" "$rc" "$output"
' _ "$TESTS_DIR" "$WORK")"
t_case "extracted gate retains selected function, consumer cwd, stderr and failure status"
t_assert_eq "$preflight_result" '23|cwd:consumer:stderr'

t_case "field receipts preserve empty values and spaces"
t_assert_eq '|two words|' "$(t_fixture_fields '' 'two words' '')"
t_case "named snapshots read imported values in caller order"
t_assert_eq 'prepared|imported' "$(t_run_sourced_module "$WORK/module.sh" 'fixture_value=prepared; original=prepared' 't_fixture_variables original fixture_value' | tail -n 1)"
root_path="$(bash -c '
  source "$1/test-workspace-fixture.sh"
  declare fixture_root
  t_fixture_workspace_init "" fixture_root || exit
  printf "%s" "$fixture_root"
' _ "$TESTS_DIR")"
t_case "suite root is returned through its explicit caller output"
t_assert_eq "$(cd "$TESTS_DIR/../../.." && pwd)" "$root_path"
workspace_path="$(bash -c '
  source "$1/test-workspace-fixture.sh"
  declare fixture_directory
  t_fixture_workspace_init fixture_directory || exit
  touch "$fixture_directory/receipt"
  printf "%s" "$fixture_directory"
' _ "$TESTS_DIR")"
t_case "suite workspace cleanup runs when its shell exits"
t_assert_rc 1 test -d "$workspace_path"
rm -rf "$workspace_path"
cat > "$WORK/pipeline.sh" <<'GATES'
pipeline_gate() {
  false | true
}
GATES
pipeline_status="$(bash -c '
  source "$1/preflight-gate-fixture.sh"
  declare fixture_directory
  preflight_gate_fixture_init fixture_directory pipeline_gate "$2/pipeline.sh" || exit
  preflight_gate_fixture_run output rc "$2" "set -uo pipefail"
  printf "%s" "$rc"
' _ "$TESTS_DIR" "$WORK")"
t_case "extracted gates retain caller shell options"
t_assert_eq 1 "$pipeline_status"
printf 'exit 99\nloaded_fixture() {\n  printf loaded\n}\n' > "$WORK/extracted.sh"
t_source_functions "$WORK/extracted.sh" loaded_fixture
t_case "named fixture functions load without running their module top level"
t_assert_eq loaded "$(loaded_fixture)"
t_case "missing fixture function definitions fail closed"
t_assert_rc 1 t_source_functions "$WORK/extracted.sh" missing_fixture
project="$(_cmake_project 'message(STATUS "fixture body")' "$WORK/project.XXXXXX")"
t_case "compiler-less project stays under its caller cleanup directory"
t_assert_eq "${project%/*}" "$WORK"
t_case "compiler-less project retains the caller body"
t_assert_ok grep -Fxq 'message(STATUS "fixture body")' "$project/CMakeLists.txt"
t_case "compiler-less project avoids compiler detection"
t_assert_ok grep -Fxq 'project(p NONE)' "$project/CMakeLists.txt"
t_summary
