#!/usr/bin/env bash
# Stubbed probe and copied-import receipts do not cover real service, namespace, network or emulator behavior.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "${TESTS_DIR}/binfmt_probe_tests.py" \
  "${1:-${TESTS_DIR}/../../host-config/install-nerdctl-full.sh}" \
  "${2:-${TESTS_DIR}/../build-runtime-manifest.sh}" \
  "${3:-${TESTS_DIR}/binfmt-probe-receipts.json}"
