#!/usr/bin/env bash
# Offline parser receipts cover numeric selection and shell failures, not actual compiler resource consumption.
exec python3 "${BASH_SOURCE[0]%/*}/clang_job_policy_tests.py" "${1:-${BASH_SOURCE[0]%/*}/../02-toolchain/build-clang.sh}"
