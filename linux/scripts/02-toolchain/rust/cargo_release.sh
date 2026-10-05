#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Logging, the CARGO_HOME and toolchain guards, safe.directory and the opt-in linker, one copy for every driver.
# shellcheck source=/dev/null
source "$SCRIPT_DIR/_cargo_wrapper.sh"

info "Running cargo release build..."
# Build all workspace members including binaries
cargo build --release --workspace "$@"

# Explicitly build the CLI binary to ensure it's available for packaging
info "Building CLI binary..."
cargo build --release -p kataglyphis_cli "$@"

info "Release build completed successfully."
