#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Logging, the CARGO_HOME and toolchain guards, safe.directory and the opt-in linker, one copy for every driver.
# shellcheck source=/dev/null
source "$SCRIPT_DIR/_cargo_wrapper.sh"
# Pins come via the safe loader, never `source`: versions.env values may hold shell metacharacters.
# shellcheck source=../../01-core/load-versions-env.sh
source "$SCRIPT_DIR/../../01-core/load-versions-env.sh"
load_versions_env "$SCRIPT_DIR/../../01-core/versions.env"
[ -n "${CARGO_AUDIT_VERSION:-}" ] || err "CARGO_AUDIT_VERSION is not set (versions.env not found?)."
[ -n "${CARGO_DENY_VERSION:-}" ] || err "CARGO_DENY_VERSION is not set (versions.env not found?)."

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

# One crate per cargo install: --version applies to every crate named on the line.
run_step "Install cargo-audit ${CARGO_AUDIT_VERSION}" \
   cargo install --locked --version "${CARGO_AUDIT_VERSION}" cargo-audit

run_step "Install cargo-deny ${CARGO_DENY_VERSION}" \
   cargo install --locked --version "${CARGO_DENY_VERSION}" cargo-deny

run_step "Run vulnerability audit (cargo audit)" \
   bash -c 'cargo audit "$@"' --

run_step "Run policy checks (cargo deny: advisories, licenses, bans, sources)" \
   bash -c 'cargo deny check advisories licenses bans sources "$@"' --

info "Security checks completed successfully"
