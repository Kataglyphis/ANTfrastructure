#!/usr/bin/env bash
# rustfmt and clippy gates; CARGO_CLIPPY_ARGS (default --all-features) scopes clippy, positionals go to fmt only.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../01-core/logging.sh
source "$SCRIPT_DIR/../../01-core/logging.sh"

# Probe through cargo, never rustup: the images bake the components in and ship no rustup.
_ensure_component() {
  local component="$1" subcommand="$2"
  if cargo "$subcommand" --version >/dev/null 2>&1; then
    return 0
  fi
  if command -v rustup >/dev/null 2>&1; then
    info "$component not present; adding it with rustup"
    rustup component add "$component"
    return 0
  fi
  err "cargo $subcommand is unavailable and there is no rustup to add '$component'. The family images bake it in at build time; on a host run 'rustup component add $component'."
}

_ensure_component rustfmt fmt
info "Checking formatting..."
# Forward any args (e.g. --features <feature>) to cargo fmt
cargo fmt --all "$@" -- --check

_ensure_component clippy clippy
info "Running clippy checks..."
CARGO_CLIPPY_ARGS="${CARGO_CLIPPY_ARGS---all-features}"
# shellcheck disable=SC2086  # a deliberate argument LIST, split by the shell
cargo clippy --all-targets ${CARGO_CLIPPY_ARGS} -- -D warnings

info "Formatting and clippy checks completed successfully."
