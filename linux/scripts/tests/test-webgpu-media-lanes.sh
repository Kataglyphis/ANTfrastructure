#!/usr/bin/env bash
# Command and graph controls do not launch units, verify parent ancestry, build ORT or prove devices.
set -euo pipefail
python3 "$(dirname "${BASH_SOURCE[0]}")/webgpu_media_lane_tests.py" "$@"
