#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../01-core/logging.sh"
# `cargo install cargo-audit cargo-deny` writes the registry under CARGO_HOME,
# which is root-owned in the runtime image; without this it fails with
# "Permission denied (os error 13)". Shared with the build wrapper.
# shellcheck source=/dev/null
source "$SCRIPT_DIR/_cargo_home_guard.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/_rust_toolchain_guard.sh"
# Both pins come from versions.env, through the SAFE loader and never `source`:
# that file is inert data whose values may contain shell metacharacters
# (CUDA_ARCHITECTURES=80;86;89;90 once ran three arch numbers as commands).
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

# ONE crate per `cargo install`: `--version X a b` applies the SAME version to
# every crate named on the line, so the two pins cannot share an invocation.
# Both were unpinned until 2026-09-09 — the two tools that decide whether this
# lane is red were the two resolving to whatever crates.io served that minute,
# so a new advisory-db schema could turn a lane red with no commit behind it.
run_step "Install cargo-audit ${CARGO_AUDIT_VERSION}" \
   cargo install --locked --version "${CARGO_AUDIT_VERSION}" cargo-audit

run_step "Install cargo-deny ${CARGO_DENY_VERSION}" \
   cargo install --locked --version "${CARGO_DENY_VERSION}" cargo-deny

run_step "Run vulnerability audit (cargo audit)" \
   bash -c 'cargo audit "$@"' --

run_step "Run policy checks (cargo deny: advisories, licenses, bans, sources)" \
   bash -c 'cargo deny check advisories licenses bans sources "$@"' --

info "Security checks completed successfully"
