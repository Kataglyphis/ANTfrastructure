#!/usr/bin/env bash
# Real OpenSSL OAEP fixtures prove encryption boundaries, not the Windows peer or private service reachability.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
t_case 'actual OAEP encryption, failure and private-file boundaries'
t_assert_ok python3 "${TESTS_DIR}/qairt_key_handoff_tests.py" "${TESTS_DIR}/../qairt-key-handoff.py"
t_case 'private transfer rejects wrong bytes, overwrites, public routes and stale receipts'
declare transfer_output transfer_status
t_capture_command transfer_output transfer_status python3 "${TESTS_DIR}/qairt_private_transfer_tests.py" "${TESTS_DIR}/../qairt-private-transfer.py"
printf '%s\n' "${transfer_output}"
t_assert_eq 0 "${transfer_status}"
t_assert_contains "${transfer_output}" 'Ran 25 tests'
t_summary
