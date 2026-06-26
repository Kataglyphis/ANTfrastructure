#!/usr/bin/env bash
set -euo pipefail
# verify-arg-consistency.sh - Verify that the auto-discovered version
# variables from versions.env match what Dockerfile ARGs expect.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
VERSIONS_ENV="${REPO_ROOT}/linux/scripts/01-core/versions.env"

echo "=== Version ARG consistency check ==="

# Use the same auto-discovery logic as version-forwarding.sh.
_VERSION_BUILD_ARG_VARS=()
while IFS= read -r varname; do
  [ -n "${varname}" ] && _VERSION_BUILD_ARG_VARS+=("${varname}")
done < <(grep -E '^[A-Z][A-Z0-9_]*(_VERSION|_RELEASE|_MAJOR_MINOR|_MAJOR|_REF|_API_LEVEL|_BUILD_TOOLS|_COMPILE_SDK)=' "${VERSIONS_ENV}" | cut -d= -f1)

echo "Auto-discovered ${#_VERSION_BUILD_ARG_VARS[@]} version variables"

# Collect all Dockerfile version ARGs
MISSING=0
for df in linux/Dockerfile.{base,toolchain,sdk,media,android,package}; do
  df_path="${REPO_ROOT}/${df}"
  [ -f "$df_path" ] || continue
  while IFS= read -r var; do
    [ -n "$var" ] || continue
    case "$var" in
      *_VERSION|*_RELEASE|*_MAJOR_MINOR|*_MAJOR|*_REF|ANDROID_API_LEVEL|ANDROID_BUILD_TOOLS|ANDROID_COMPILE_SDK) ;;
      *) continue ;;
    esac
    found=0
    for v in "${_VERSION_BUILD_ARG_VARS[@]}"; do
      [ "$v" = "$var" ] && { found=1; break; }
    done
    if [ "$found" -eq 0 ]; then
      echo "WARN: ${df} has ARG '${var}' not in versions.env auto-discover list"
      MISSING=$((MISSING + 1))
    fi
  done < <(grep -oP '^\s*ARG\s+\K[A-Z_]+(?=\s*=)' "$df_path" || true)
done

if [ "$MISSING" -gt 0 ]; then
  echo "WARNING: ${MISSING} ARG(s) may not be auto-forwarded to builds"
  echo "Review version-forwarding.sh or add to _MANUAL_VARS in this script"
else
  echo "All version ARGs covered by auto-discovery"
fi

echo "DONE: version ARG consistency check"
