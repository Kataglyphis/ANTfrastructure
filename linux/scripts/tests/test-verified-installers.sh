#!/usr/bin/env bash
# Offline receipts cover installer and copied-import policy, not network or package behavior; they pin mktemp's default /tmp template.
exec env -u TMPDIR python3 "${BASH_SOURCE[0]%/*}/verified_installer_tests.py" "${1:-${BASH_SOURCE[0]%/*}/..}"
