#!/usr/bin/env bash
# Private files and fake tool faults cover QNN queries and imports, not actual EP loading or SDK compatibility.
exec python3 "${BASH_SOURCE[0]%/*}/qnn_query_tests.py" "${1:-${BASH_SOURCE[0]%/*}/..}"
