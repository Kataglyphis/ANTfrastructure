#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../01-core/logging.sh"

info "Running cargo benchmarks..."
# Forward args to cargo bench
cargo bench "$@"

info "Benchmarks completed successfully."
