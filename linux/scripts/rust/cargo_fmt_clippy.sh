#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../01-core/logging.sh"

info "Adding rustfmt component and checking formatting..."
rustup component add rustfmt
# Forward any args (e.g. --features <feature>) to cargo fmt
cargo fmt --all -- --check "$@"

info "Adding clippy component and running clippy checks..."
rustup component add clippy
# Forward any args to cargo clippy
cargo clippy --all-targets --all-features -- -D warnings "$@"

info "Formatting and clippy checks completed successfully."
