#!/usr/bin/env bash
# Extracted gates run in disposable consumer trees without invoking the rest of preflight.
# shellcheck source=linux/scripts/tests/test-workspace-fixture.sh
source "${BASH_SOURCE[0]%/*}/test-workspace-fixture.sh"

preflight_gate_fixture_init() {
  local -n _pgf_workspace_ref="$1"
  t_fixture_workspace_init "$1" REPO_ROOT || return 1
  local function_source
  _PREFLIGHT_FIXTURE_FUNCTION="$2"
  function_source="$(t_fn_src "${3:-${REPO_ROOT}/linux/scripts/preflight.sh}" "$2")" || return 1
  _PREFLIGHT_FIXTURE_WORK="$_pgf_workspace_ref"
  printf '%s\n' "$function_source" > "${_pgf_workspace_ref}/guard.sh"
}

preflight_gate_fixture_run() {
  local output_name="$1" status_name="$2" directory="$3" captured status
  captured="$(cd "$directory" && bash -c "${4:-set -u}"'; source "$1"; "$2"' _ \
    "${_PREFLIGHT_FIXTURE_WORK}/guard.sh" "${_PREFLIGHT_FIXTURE_FUNCTION}" 2>&1)"
  status=$?
  printf -v "$output_name" '%s' "$captured"
  printf -v "$status_name" '%s' "$status"
}
