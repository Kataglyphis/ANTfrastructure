#!/usr/bin/env bash
# _cargo_wrapper.sh — shared scaffolding for the single-command cargo_*.sh
# step wrappers. Sourced (not executed) by cargo_bench.sh / cargo_debug.sh /
# cargo_test.sh, which reduce to a single cargo_step call. Keeping each wrapper
# as its own file preserves the "invoked by name" contract.
set -euo pipefail

_CARGO_WRAPPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$_CARGO_WRAPPER_DIR/../../01-core/logging.sh"

# Writable-CARGO_HOME guard, shared with cargo_security_checks.sh (which does
# `cargo install` and hit the same root-owned CARGO_HOME). Extracted so a third
# cargo step cannot regress by forgetting it.
# shellcheck source=/dev/null
source "$_CARGO_WRAPPER_DIR/_cargo_home_guard.sh"

# cargo_step <start-msg> <done-msg> -- <command...>
# Logs <start-msg>, runs <command...>, then logs <done-msg>. The `--` separates
# the two message args from the command so messages may contain spaces.
cargo_step() {
  local start_msg="$1" done_msg="$2"
  shift 2
  [ "${1:-}" = "--" ] && shift
  info "${start_msg}"
  "$@"
  info "${done_msg}"
}
