#!/usr/bin/env bash
# Keep behavior in the hub driver; see docs/dependency-updates.md.
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_SCRIPT_DIR}/lib/antfrastructure.sh"

# No preconditions here: upstream owns and tests them, and a second copy only disagrees.
antfrastructure_exec linux/scripts/renovate-local.sh "$KATAGLYPHIS_REPO_ROOT" "$@"
