#!/usr/bin/env bash
# Compiled pinned-source registry lifetimes and negative ASan controls do not prove a real SDK or GPU.
set -euo pipefail
python3 "$(dirname "${BASH_SOURCE[0]}")/ort_migraphx_factory_tests.py"
