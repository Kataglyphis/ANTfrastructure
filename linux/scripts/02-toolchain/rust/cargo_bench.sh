#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_cargo_wrapper.sh"

# Forward args to cargo bench
cargo_step "Running cargo benchmarks..." "Benchmarks completed successfully." -- \
  cargo bench "$@"
