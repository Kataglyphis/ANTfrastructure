#!/usr/bin/env bash
# Actual service sections run only with stubs and a blocked external PATH; no installer, sudo or real service is executed.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "${TESTS_DIR}/nerdctl_service_receipt_tests.py" \
  "${1:-${TESTS_DIR}/../../host-config/install-nerdctl-full.sh}" \
  "${TESTS_DIR}/nerdctl-service-receipts.json"
