#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Logging, the CARGO_HOME and toolchain guards, safe.directory and the opt-in linker, one copy for every driver.
# shellcheck source=/dev/null
source "$SCRIPT_DIR/_cargo_wrapper.sh"

# Pinned tarpaulin, or coverage moves on its own; the pin comes via the safe loader, never `source`.
# shellcheck source=../../01-core/load-versions-env.sh
source "$SCRIPT_DIR/../../01-core/load-versions-env.sh"
load_versions_env "$SCRIPT_DIR/../../01-core/versions.env"
[ -n "${CARGO_TARPAULIN_VERSION:-}" ] || err "CARGO_TARPAULIN_VERSION is not set (versions.env not found?)."

cargo_install_pinned cargo-tarpaulin "${CARGO_TARPAULIN_VERSION}"

info "Running coverage with tarpaulin..."
# Forward any arguments (for example: --features <feature>) to cargo-tarpaulin
cargo tarpaulin --ignore-tests --out Html --out Xml --engine llvm "$@"

info "Coverage report generated successfully."
