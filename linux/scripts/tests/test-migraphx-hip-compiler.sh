#!/usr/bin/env bash
# Synthetic ELF and compiler doubles prove refusal and transport, not real HIP code generation or inference.
set -euo pipefail
python3 "$(dirname "${BASH_SOURCE[0]}")/migraphx_hip_compiler_tests.py"
