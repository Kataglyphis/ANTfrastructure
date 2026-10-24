#!/usr/bin/env bash
# Stubbed queries cover candidate and failure policy, not actual compiler availability or ABI correctness.
exec python3 "${BASH_SOURCE[0]%/*}/compiler_candidate_tests.py" "${1:-${BASH_SOURCE[0]%/*}/../01-core/compiler-resolution.sh}"
