#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_cargo_wrapper.sh"

# Forward args to cargo build (e.g. --features <feature>)
cargo_step "Running cargo debug build..." "Debug build completed successfully." -- \
  cargo build --verbose "$@"
