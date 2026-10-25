#!/usr/bin/env bash
# Keep behavior in the hub driver; see docs/dependency-updates.md.
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_SCRIPT_DIR}/lib/antfrastructure.sh"

# The copied bootstrap initializes this hub only for a real apply; upstream owns the update.
antfrastructure_renovate_exec linux/scripts/renovate-local.sh "$KATAGLYPHIS_REPO_ROOT" "$@"
