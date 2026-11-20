#!/usr/bin/env bash
# Native identity and lifecycle fixtures do not establish a genuine MIGraphX build, complete licences or inference.
set -euo pipefail
python3 "$(dirname "${BASH_SOURCE[0]}")/migraphx_backend_build_tests.py"
