#!/usr/bin/env bash
# These metadata and lifecycle doubles do not compile rocMLIR or establish binary linkage or licence closure.
set -euo pipefail
python3 "$(dirname "${BASH_SOURCE[0]}")/migraphx_rocmlir_build_tests.py"
