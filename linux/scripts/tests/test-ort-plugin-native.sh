#!/usr/bin/env bash
# Fake C API callbacks prove path, cache, device and error policy, not real ORT ABI or inference.
set -euo pipefail
python3 "$(dirname "${BASH_SOURCE[0]}")/ort_plugin_native_tests.py"
