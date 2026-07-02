#!/usr/bin/env bash
set -euo pipefail
# verify-arg-consistency.sh - Verify that versions.env, the build-arg
# forwarding, and the Dockerfile ARG safety-net defaults agree:
#   1. Every Dockerfile ARG whose name is a versions.env variable must be
#      forwarded by version-forwarding.sh (i.e. not marked `# noforward`).
#   2. Every such ARG's literal default must equal the versions.env value.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
VERSIONS_ENV="${REPO_ROOT}/linux/scripts/01-core/versions.env"

# Same Dockerfile set as docs/scripts/sync_versions.py dockerfile_target_files().
DOCKERFILES=(base toolchain sdk media android package torch nvidia amd)

echo "=== Version ARG consistency check ==="

# Reuse the discovery from version-forwarding.sh (single definition of the
# forward-all-except-`# noforward` rule and of _VERSION_BUILD_ARG_VARS).
# shellcheck disable=SC1091
source "${REPO_ROOT}/linux/scripts/01-core/version-forwarding.sh"

echo "Discovered ${#_VERSION_BUILD_ARG_VARS[@]} forwarded variables"

# Load versions.env into associative array (all vars, including noforward).
declare -A _version_values
while IFS='=' read -r key val; do
  [ -n "$key" ] && _version_values["$key"]="$val"
done < <(grep -E '^[A-Z][A-Z0-9_]*=' "${VERSIONS_ENV}" || true)

MISSING=0
for name in "${DOCKERFILES[@]}"; do
  df="linux/Dockerfile.${name}"
  df_path="${REPO_ROOT}/${df}"
  [ -f "$df_path" ] || continue
  while IFS='=' read -r var val_raw; do
    [ -n "$var" ] || continue
    # ARGs derived from another ARG (e.g. PYTHON_MAJOR_MINOR=${PYTHON_VERSION%.*})
    # are computed in-Dockerfile and need no forwarding from versions.env.
    case "$val_raw" in '${'*) continue ;; esac
    # Only ARGs whose name exists in versions.env are expected to be forwarded.
    [ -n "${_version_values[$var]:-}" ] || continue
    found=0
    for v in "${_VERSION_BUILD_ARG_VARS[@]}"; do
      [ "$v" = "$var" ] && { found=1; break; }
    done
    if [ "$found" -eq 0 ]; then
      echo "WARN: ${df} ARG '${var}' consumes a versions.env value that is not forwarded (marked # noforward?)"
      MISSING=$((MISSING + 1))
    fi
  done < <(grep -oP '^\s*ARG\s+\K[A-Z_]+=("[^"]*"|\S+)' "$df_path" || true)
done

if [ "$MISSING" -gt 0 ]; then
  echo "WARNING: ${MISSING} ARG(s) may not be auto-forwarded to builds"
  echo "Remove the # noforward marker in versions.env or drop the Dockerfile ARG"
else
  echo "All version ARGs covered by forwarding"
fi

echo ""
echo "=== ARG default value check ==="

VALUE_ERRORS=0
for name in "${DOCKERFILES[@]}"; do
  df="linux/Dockerfile.${name}"
  df_path="${REPO_ROOT}/${df}"
  [ -f "$df_path" ] || continue
  while IFS='=' read -r var val_raw; do
    [ -z "$var" ] && continue
    env_val="${_version_values[$var]:-}"
    [ -z "$env_val" ] && continue
    # Derived ARGs (default computed from another ARG) have no literal to compare.
    case "$val_raw" in '${'*) continue ;; esac
    # Strip surrounding double quotes from Dockerfile value
    val="${val_raw%\"}"
    val="${val#\"}"
    if [ "$val" != "$env_val" ]; then
      echo "  DRIFT: ${df} ARG ${var}=${val}  ≠  versions.env ${var}=${env_val}"
      VALUE_ERRORS=$((VALUE_ERRORS + 1))
    fi
  done < <(grep -oP '^\s*ARG\s+\K[A-Z_]+=("[^"]*"|\S+)' "$df_path" || true)
done

if [ "$VALUE_ERRORS" -gt 0 ]; then
  echo "ERROR: ${VALUE_ERRORS} ARG default(s) differ from versions.env"
  echo "Run: python3 docs/scripts/sync_versions.py --write"
  exit 1
else
  echo "All ARG defaults match versions.env"
fi

echo "DONE: version ARG consistency check"
