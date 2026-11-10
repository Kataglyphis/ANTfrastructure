#!/usr/bin/env bash
# Fake bindings prove registration and device-selection policy, not native loading or GPU inference.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
python3 -m unittest discover -s shared/python/tests -p test_ort_plugin_eps.py
