#!/usr/bin/env bash
# Real OpenSSL OAEP fixtures prove encryption boundaries, not the Windows peer or private service reachability.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
t_case 'actual OAEP encryption, failure and private-file boundaries'
t_assert_ok python3 "${TESTS_DIR}/qairt_key_handoff_tests.py" "${TESTS_DIR}/../qairt-key-handoff.py"
t_summary
