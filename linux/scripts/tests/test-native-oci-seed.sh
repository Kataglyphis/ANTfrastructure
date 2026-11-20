#!/usr/bin/env bash
# Synthetic OCI bytes and real tar verify transport and sharing, never actual image or GPU acceptance.
set -euo pipefail
python3 "$(dirname "${BASH_SOURCE[0]}")/native_oci_seed_tests.py" "$@"
