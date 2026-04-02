#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../01-core/logging.sh"

info "Installing cargo-tarpaulin..."
cargo install cargo-tarpaulin

info "Running coverage with tarpaulin..."
# Forward any arguments (for example: --features <feature>) to cargo-tarpaulin
cargo tarpaulin --ignore-tests --out Html --out Xml --engine llvm "$@"

info "Coverage report generated successfully."
