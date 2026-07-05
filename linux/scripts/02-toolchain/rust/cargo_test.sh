#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_cargo_wrapper.sh"

# Forward args to cargo test (e.g. --features <feature>)
cargo_step "Running cargo tests..." "Tests completed successfully." -- \
  cargo test --all --verbose "$@"
