#!/usr/bin/env bash
set -euo pipefail

# Prefers the container's mounted LiteRT script, falling back to the repo's sibling for local runs.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CENTRAL="/opt/scripts/03-media/build/litert/build-litert.sh"
REPO_REL="$(cd "${SCRIPT_DIR}/../../litert" 2>/dev/null && pwd || true)/build-litert.sh"

if [ -x "${CENTRAL}" ]; then
  exec "${CENTRAL}" "$@"
elif [ -x "${REPO_REL}" ]; then
  exec "${REPO_REL}" "$@"
else
  echo "LiteRT build script not found in ${CENTRAL} or ${REPO_REL}" >&2
  exit 1
fi
