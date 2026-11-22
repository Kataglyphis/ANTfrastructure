#!/usr/bin/env bash
# Synthetic process identity and unit doubles exercise real file copies; no vendor build, linkage, provenance or image is accepted.
set -euo pipefail
python3 "$(dirname "${BASH_SOURCE[0]}")/live_configure_snapshot_tests.py" "$@"
