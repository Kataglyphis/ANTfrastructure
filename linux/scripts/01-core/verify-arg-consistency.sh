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

echo ""
echo "=== Script :- default drift check (advisory) ==="
# Many build scripts embed a hardcoded fallback for a versions.env variable as
# ${VAR:-literal} (a "third channel": the value is neither an ARG default nor
# read from versions.env at runtime — several scripts don't source
# load_versions_env). Those literals can silently drift from versions.env.
# This check surfaces such drift. It is ADVISORY (never fails the build) because,
# unlike Dockerfile ARG defaults, script defaults legitimately diverge:
#   * TVM_REF: tvm.sh defaults to the 'main' branch for standalone runs, while
#     versions.env pins the built ref.
#   * PYTHON_VERSION: CI tooling defaults to a MAJOR.MINOR (3.14) to name the
#     interpreter, not the full patch version.
# Add such intentional cases to SCRIPT_DEFAULT_DRIFT_ALLOW below.
declare -A SCRIPT_DEFAULT_DRIFT_ALLOW=( [TVM_REF]=1 [PYTHON_VERSION]=1 )
DRIFT_WARN=0
while IFS= read -r hit; do
  # hit is "path:${VAR:-literal}"
  file="${hit%%:*}"; match="${hit#*:}"
  var="${match#\$\{}"; var="${var%%:-*}"
  lit="${match#*:-}"; lit="${lit%\}}"
  # Only versions.env variables with a non-empty value are comparable.
  env_val="${_version_values[$var]:-}"
  [ -n "$env_val" ] || continue
  [ -n "${SCRIPT_DEFAULT_DRIFT_ALLOW[$var]:-}" ] && continue
  # Skip non-literal fallbacks: empty, the 'unset' sentinel, nested expansions
  # (${..$..}), command substitutions, or backticks — not values to compare.
  case "$lit" in ''|unset|*'$'*|*'('*|*'`'*) continue ;; esac
  env_val="${env_val%\"}"; env_val="${env_val#\"}"   # strip surrounding quotes
  if [ "$lit" != "$env_val" ]; then
    echo "  WARN drift: ${file}  \${${var}:-${lit}}  ≠  versions.env ${var}=${env_val}"
    DRIFT_WARN=$((DRIFT_WARN + 1))
  fi
done < <(grep -rloP '\$\{[A-Z][A-Z0-9_]*:-[^}]*\}' "${REPO_ROOT}/linux/scripts" --include='*.sh' 2>/dev/null \
         | while read -r f; do grep -oP '\$\{[A-Z][A-Z0-9_]*:-[^}]*\}' "$f" | sed "s|^|${f}:|"; done)
if [ "$DRIFT_WARN" -gt 0 ]; then
  echo "NOTE: ${DRIFT_WARN} script default(s) differ from versions.env (advisory only)."
  echo "If intentional, add the variable to SCRIPT_DEFAULT_DRIFT_ALLOW in this script."
else
  echo "No script :- default drift detected"
fi

echo "DONE: version ARG consistency check"
