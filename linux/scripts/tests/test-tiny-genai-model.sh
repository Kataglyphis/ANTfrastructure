#!/usr/bin/env bash
# The fixture bytes and its oracle, read back on any host; a real decode needs the image wheel and the --check mode.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "${TESTS_DIR}/tiny_genai_model_tests.py" "${1:-${TESTS_DIR}/../lib/tiny-genai-model.py}"
