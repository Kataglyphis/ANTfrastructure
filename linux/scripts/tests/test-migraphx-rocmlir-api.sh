#!/usr/bin/env bash
# Compiled original-header fixtures and transport doubles do not establish the actual rocMLIR vendor SDK or GPU inference.
set -euo pipefail
python3 "$(dirname "${BASH_SOURCE[0]}")/migraphx_rocmlir_api_tests.py"
