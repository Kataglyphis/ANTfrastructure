#!/usr/bin/env bash
# Tests generated ABI flags, not a linked Rust/C++ binary.
set -euo pipefail
python3 "$(dirname "${BASH_SOURCE[0]}")/test-corrosion-toolchain.py"
