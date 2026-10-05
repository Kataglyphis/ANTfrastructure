#!/usr/bin/env bash
# Scaffolding for the one-command cargo_*.sh wrappers, which stay separate files so callers invoke them by name.
set -euo pipefail

_CARGO_WRAPPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$_CARGO_WRAPPER_DIR/../../01-core/logging.sh"

# Writable-CARGO_HOME guard, shared with cargo_security_checks.sh.
# shellcheck source=/dev/null
source "$_CARGO_WRAPPER_DIR/_cargo_home_guard.sh"

# The images also carry Ubuntu's Rust debs, which would otherwise mix into the pinned toolchain.
# shellcheck source=/dev/null
source "$_CARGO_WRAPPER_DIR/_rust_toolchain_guard.sh"

# Opt-in (KATAGLYPHIS_LINKER); a value that cannot link stops here, under set -e.
# shellcheck source=/dev/null
source "$_CARGO_WRAPPER_DIR/../../lib/linker-select.sh"
linker_select_env

# cargo_step <start-msg> <done-msg> -- <command...>; the -- lets messages contain spaces.
cargo_step() {
  local start_msg="$1" done_msg="$2"
  shift 2
  [ "${1:-}" = "--" ] && shift
  info "${start_msg}"
  "$@"
  info "${done_msg}"
}
