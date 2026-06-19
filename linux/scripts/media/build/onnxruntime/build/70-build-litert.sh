#!/usr/bin/env bash
set -euo pipefail

# Lightweight wrapper: prefer the centralized litert script location used by
# media scripts (/opt/scripts/media/litert) when present in a container build
# stage. If not available, fall back to the repository's sibling litert
# directory (useful for running locally from the repo).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CENTRAL="/opt/scripts/media/litert/build-litert.sh"
REPO_REL="$(cd "${SCRIPT_DIR}/../../litert" 2>/dev/null && pwd || true)/build-litert.sh"

if [ -x "${CENTRAL}" ]; then
  exec "${CENTRAL}" "$@"
elif [ -x "${REPO_REL}" ]; then
  exec "${REPO_REL}" "$@"
else
  echo "LiteRT build script not found in ${CENTRAL} or ${REPO_REL}" >&2
  exit 1
fi
