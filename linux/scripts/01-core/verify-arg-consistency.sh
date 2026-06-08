#!/usr/bin/env bash
set -euo pipefail
# verify-arg-consistency.sh - Verify that _VERSION_BUILD_ARG_VARS in
# artifact-common.sh covers all version variables from versions.env, and
# identify Dockerfile ARGs that may need adding to the forwarding list.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
ARTIFACT_COMMON="${REPO_ROOT}/linux/scripts/01-core/artifact-common.sh"
VERSIONS_ENV="${REPO_ROOT}/linux/scripts/01-core/versions.env"
errors=0

echo "=== Version ARG consistency check ==="

# Parse _VERSION_BUILD_ARG_VARS from artifact-common.sh
_BUILD_ARG_VARS="$(
  sed -n '/^_VERSION_BUILD_ARG_VARS=(/,/^)/p' "${ARTIFACT_COMMON}" \
    | sed '1s/^_VERSION_BUILD_ARG_VARS=(//' \
    | sed '$s/)$//' \
    | tr '\n' ' ' | tr -s ' ' | xargs -n1 echo | sort -u
)"

# 1. Every var in the list must exist in versions.env
for var in $_BUILD_ARG_VARS; do
  if ! grep -q "^${var}=" "${VERSIONS_ENV}"; then
    echo "ERROR: _VERSION_BUILD_ARG_VARS lists '${var}' but not in versions.env" >&2
    errors=$((errors + 1))
  fi
done

# 2. Core version vars in versions.env should be in the forwarding list
VERSION_VAR_PATTERN='^(UBUNTU_VERSION|CMAKE_VERSION|NODE_VERSION|UV_VERSION|LLVM_RELEASE|GCC_VERSION|PYTHON_VERSION|PYTHON_MAJOR_MINOR|VULKAN_VERSION|ONNXRUNTIME_VERSION|ONNXRUNTIME_GENAI_VERSION|LITERT_VERSION|OPENCV_VERSION|GSTREAMER_VERSION|ANDROID_SDK_VERSION|ANDROID_NDK_VERSION|ANDROID_COMPILE_SDK|ANDROID_BUILD_TOOLS|ANDROID_CMAKE_VERSION|ANDROID_API_LEVEL|TVM_REF|CUDA_VERSION|CUDA_VERSION_MAJOR_MINOR|CUDNN_VERSION|TENSORRT_VERSION|ROCM_VERSION)='

while IFS='=' read -r line; do
  key="${line%%=*}"
  [ -n "$key" ] || continue
  [ "${key:0:1}" = "#" ] && continue
  if echo "${key}=" | grep -qE "${VERSION_VAR_PATTERN}"; then
    found=0
    for v in $_BUILD_ARG_VARS; do
      [ "$v" = "$key" ] && { found=1; break; }
    done
    if [ "$found" -eq 0 ]; then
      echo "WARN: versions.env '${key}' is not forwarded by _VERSION_BUILD_ARG_VARS" >&2
    fi
  fi
done < "${VERSIONS_ENV}"

# 3. Dockerfile version ARG coverage
DOCKERFILES=(
  linux/Dockerfile.base linux/Dockerfile.toolchain linux/Dockerfile.sdk
  linux/Dockerfile.media linux/Dockerfile.android linux/Dockerfile.package
)

for df in "${DOCKERFILES[@]}"; do
  df_path="${REPO_ROOT}/${df}"
  [ -f "$df_path" ] || continue
  df_version_args="$(
    grep -oP 'ARG\s+([A-Z_]+)\s*=\s*\S+' "$df_path" \
      | sed 's/ARG\s*//' | sed 's/\s*=.*$//' | sort -u
  )"
  for var in $df_version_args; do
    # Only flag vars that look like version numbers
    case "$var" in
      *_VERSION|*_RELEASE|*_SDK|*_NDK|*_API_LEVEL|*_COMPILE_SDK|*_BUILD_TOOLS|*_MAJOR_MINOR) ;;
      TVM_REF) ;;  # only this specific REF is a version
      *) continue ;;
    esac
    found=0
    for v in $_BUILD_ARG_VARS; do
      [ "$v" = "$var" ] && { found=1; break; }
    done
    if [ "$found" -eq 0 ]; then
      echo "WARN: ${df} version ARG '${var}' not in _VERSION_BUILD_ARG_VARS" >&2
    fi
  done
done

if [ "$errors" -gt 0 ]; then
  echo "FAILED: ${errors} consistency errors" >&2
  exit 1
fi
echo "PASSED: version ARG consistency OK"
