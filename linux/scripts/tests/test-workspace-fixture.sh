#!/usr/bin/env bash
# Suite workspaces keep disposable inputs and their exit cleanup under one owner.
t_fixture_workspace_init() {
  source "${BASH_SOURCE[0]%/*}/test-harness.sh"
  if [ -n "${2:-}" ]; then
    local -n _tfw_root_output="$2"
    _tfw_root_output="$(cd "${BASH_SOURCE[0]%/*}/../../.." && pwd)" || return 1
  fi
  if [ -n "${1:-}" ]; then
    local -n _tfw_output="$1"
    _tfw_output="$(mktemp -d)" || return 1
    _TEST_FIXTURE_WORKSPACE="$_tfw_output"
    trap 'rm -rf "${_TEST_FIXTURE_WORKSPACE}"' EXIT
  fi
}
