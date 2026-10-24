#!/usr/bin/env bash
# Stubbed process probes preserve sibling decisions without signalling processes or starting chains.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "${TESTS_DIR}/chain_sibling_pid_tests.py" "${1:-${TESTS_DIR}/../build-cross-chain.sh}"
