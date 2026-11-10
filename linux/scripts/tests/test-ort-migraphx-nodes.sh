#!/usr/bin/env bash
# Compiled pinned-source slices prove cleanup policy and callback adjustment, not SDK or GPU inference.
set -euo pipefail
python3 "$(dirname "${BASH_SOURCE[0]}")/ort_migraphx_nodes_tests.py"
