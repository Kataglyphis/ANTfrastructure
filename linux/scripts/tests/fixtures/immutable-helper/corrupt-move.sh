#!/usr/bin/env bash
# A successful move that changed payload bytes must fail before a launcher replaces the source.
set -euo pipefail
"${REAL_MV_PATH}" "$@"
target="${!#}"
printf 'changed after the move\n' >>"${target}"
