#!/usr/bin/env bash
# Mocked finds and private header copies cover discovery policy, not actual compiler builds or SDK completeness.
exec python3 "${BASH_SOURCE[0]%/*}/header_discovery_tests.py" "${1:-${BASH_SOURCE[0]%/*}/..}"
