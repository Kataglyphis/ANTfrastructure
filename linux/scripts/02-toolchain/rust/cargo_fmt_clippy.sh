#!/usr/bin/env bash
# cargo_fmt_clippy.sh - rustfmt --check and clippy -D warnings over a crate.
#
# PROBE, DO NOT ADD. This script used to open with `rustup component add rustfmt`,
# which made it unusable in the image it exists for: the runtime stage ships NO
# rustup (install-rust.sh bakes rustfmt and clippy in at image-build time), so it
# exited 127 before cargo ever ran. OxidANT's rust_ubuntu26_04.yml:134-139 records
# that as "it died with exit 127 on every single build", and both of its lanes
# hand-rolled the two cargo calls to get around it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../01-core/logging.sh
source "$SCRIPT_DIR/../../01-core/logging.sh"

# Already available, else installable, else a hard error naming both ways out.
# The probe is the component's own --version THROUGH cargo, not `rustup component
# list`: in the baked-in case there is no rustup to ask.
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
# Forward any args to cargo clippy
cargo clippy --all-targets --all-features "$@" -- -D warnings

info "Formatting and clippy checks completed successfully."
