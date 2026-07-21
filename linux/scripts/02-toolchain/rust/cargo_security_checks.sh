#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../01-core/logging.sh"
# `cargo install cargo-audit cargo-deny` writes the registry under CARGO_HOME,
# which is root-owned in the runtime image; without this it fails with
# "Permission denied (os error 13)". Shared with the build wrapper.
# shellcheck source=/dev/null
source "$SCRIPT_DIR/_cargo_home_guard.sh"

run_step() {
   local description="$1"
   shift

   info "Starting: ${description}"
   if "$@"; then
       info "Completed: ${description}"
   else
       local exit_code=$?
       err "Failed: ${description} (exit code: ${exit_code})"
       exit "${exit_code}"
   fi
}

info "Security checks started"

run_step "Install security tooling (cargo-audit, cargo-deny)" \
   cargo install --locked cargo-audit cargo-deny

run_step "Run vulnerability audit (cargo audit)" \
   bash -c 'cargo audit "$@"' --

run_step "Run policy checks (cargo deny: advisories, licenses, bans, sources)" \
   bash -c 'cargo deny check advisories licenses bans sources "$@"' --

info "Security checks completed successfully"
