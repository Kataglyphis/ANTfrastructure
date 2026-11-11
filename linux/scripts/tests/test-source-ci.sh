#!/usr/bin/env bash
# Synthetic source proofs exercise verdict failures, not GitHub access, container execution or GPU inference.
set -euo pipefail
python3 "$(dirname "${BASH_SOURCE[0]}")/source_ci_tests.py"
