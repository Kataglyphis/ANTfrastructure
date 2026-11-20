#!/usr/bin/env bash
# Temporary OCI controls do not authenticate receipt roots or model malicious concurrent writers.
set -euo pipefail
python3 "$(dirname "${BASH_SOURCE[0]}")/oci_archive_dedup_tests.py" "$@"
