#!/usr/bin/env bash
# Reuse the selected-file transport for each requested member of one synthetic tree.
set -euo pipefail
export EXPECTED_ENTRY="${2:?}" EXPECTED_FILE="${APPIMAGE_SOURCE_TREE:?}/${2}"
exec bash "${APPIMAGE_SELECTED_FILE_FIXTURE:?}" "$@"
