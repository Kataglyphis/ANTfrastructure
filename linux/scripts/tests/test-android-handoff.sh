#!/usr/bin/env bash
# Synthetic OCI and command controls do not prove an actual Android build, source authentication, licences or GPU acceptance.
set -euo pipefail
python3 "$(dirname "${BASH_SOURCE[0]}")/android_handoff_tests.py" "$@"
