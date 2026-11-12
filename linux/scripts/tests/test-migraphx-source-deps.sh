#!/usr/bin/env bash
# Command doubles prove transport and notice policy; they do not compile vendor C++ or accept a GPU image.
set -euo pipefail
python3 "$(dirname "${BASH_SOURCE[0]}")/migraphx_source_deps_tests.py"
