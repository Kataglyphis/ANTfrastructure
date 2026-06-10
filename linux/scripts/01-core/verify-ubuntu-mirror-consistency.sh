#!/usr/bin/env bash
set -euo pipefail
# verify-ubuntu-mirror-consistency.sh - Check that every Dockerfile has the
# canonical Ubuntu mirror ARGs and use-fast-ubuntu-mirror.sh RUN step.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
errors=0

echo "=== Ubuntu mirror consistency check ==="

DOCKERFILES=(
  linux/Dockerfile.base
  linux/Dockerfile.toolchain
  linux/Dockerfile.sdk
  linux/Dockerfile.media
  linux/Dockerfile.android
  linux/Dockerfile.package
  linux/Dockerfile.torch
)

REQUIRED_ARGS=(
  "USE_FAST_UBUNTU_MIRROR"
  "FAST_UBUNTU_MIRROR_URL"
  "FAST_UBUNTU_PORTS_MIRROR_URL"
)

for df in "${DOCKERFILES[@]}"; do
  df_path="${REPO_ROOT}/${df}"
  [ -f "$df_path" ] || continue

  for arg in "${REQUIRED_ARGS[@]}"; do
    if ! grep -q "ARG ${arg}" "$df_path"; then
      echo "ERROR: ${df} is missing ARG ${arg}" >&2
      errors=$((errors + 1))
    fi
  done

  if ! grep -q 'use-fast-ubuntu-mirror.sh' "$df_path"; then
    echo "ERROR: ${df} is missing use-fast-ubuntu-mirror.sh RUN" >&2
    errors=$((errors + 1))
  fi
done

if [ "$errors" -gt 0 ]; then
  echo "FAILED: ${errors} mirror consistency errors" >&2
  exit 1
fi
echo "PASSED: Ubuntu mirror pattern consistent across all Dockerfiles"
