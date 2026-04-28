#!/usr/bin/env bash
# ==============================================================================
# 30-build-native-amd.sh
# Build ONNX Runtime with ROCm Execution Provider.
#
# Requires:
#   - ROCm toolkit in /opt/rocm
#
# Outputs:
#   - Shared libs + headers → ${NATIVE_GPU_OUTPUT_DIR}
#   - Wheel files            → ${NATIVE_GPU_OUTPUT_DIR}/wheels
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# Source build acceleration helpers if available
for helper in \
    "/opt/scripts/core/compiler-cache.sh" \
    "${SCRIPT_DIR}/../../../../01-core/compiler-cache.sh"; do
    if [ -f "${helper}" ]; then
        source "${helper}"
        break
    fi
done

ORT_VERSION="${1:---ort-version}"
shift || true
BUILD_TYPE="${1:---build-type}"
shift || true

echo "Building ONNX Runtime ${ORT_VERSION} (${BUILD_TYPE}) with ROCm..."
# Call the common build script with ROCm args
bash "${SCRIPT_DIR}/20-build-native-common.sh" \
    --ort-version "${ORT_VERSION}" \
    --build-type "${BUILD_TYPE}" \
    --use_rocm \
    --rocm_home "/opt/rocm" \
    --rocm_version "${ROCM_VERSION:-6.1}" \
    "$@"
