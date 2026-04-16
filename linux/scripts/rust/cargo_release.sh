#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../01-core/logging.sh"

info "Running cargo release build..."
# Build all workspace members including binaries
cargo build --release --workspace "$@"

info "Release build completed successfully."
