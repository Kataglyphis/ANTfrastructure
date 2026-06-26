#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../01-core/logging.sh"

info "Running cargo debug build..."
# Forward args to cargo build (e.g. --features <feature>)
cargo build --verbose "$@"

info "Debug build completed successfully."
