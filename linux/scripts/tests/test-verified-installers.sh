#!/usr/bin/env bash
# Offline receipts cover installer and copied-import policy, not network integrity or installed package behavior.
exec python3 "${BASH_SOURCE[0]%/*}/verified_installer_tests.py" "${1:-${BASH_SOURCE[0]%/*}/..}"
