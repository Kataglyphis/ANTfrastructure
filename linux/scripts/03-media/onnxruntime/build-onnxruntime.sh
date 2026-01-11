#!/usr/bin/env bash
set -euxo pipefail                                   

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
ORT_VERSION="${ORT_VERSION:-v1.23.2}"
ORT_REPO="${ORT_REPO:-https://github.com/microsoft/onnxruntime.git}"
ORT_SRC_DIR="${ORT_SRC_DIR:-/opt/onnxruntime}"
WASM_OUTPUT_DIR="/usr/local/lib/onnxruntime-web"

# -----------------------------------------------------------------------------
# Compute JOBS
# -----------------------------------------------------------------------------
if [ -z "${JOBS:-}" ]; then
    CORES="$(nproc --all)"
    AVAIL_MB="$(awk '/MemAvailable/ {printf("%d",$2/1024); exit}' /proc/meminfo || true)"
    [ -z "${AVAIL_MB}" ] && AVAIL_MB=2048
    MAX_BY_MEM=$(( AVAIL_MB / 2000 ))
    JOBS=$(( CORES < MAX_BY_MEM ? CORES : MAX_BY_MEM ))
    [ "${JOBS}" -lt 1 ] && JOBS=1
fi

export JOBS
export CMAKE_BUILD_PARALLEL_LEVEL="${JOBS}"

# -----------------------------------------------------------------------------
# Dependencies & Setup
# -----------------------------------------------------------------------------
DEBIAN_FRONTEND=noninteractive apt-get update
apt-get install -y --no-install-recommends \
    git ca-certificates curl wget build-essential pkg-config \
    python3 python3-dev python3-pip cmake ninja-build zlib1g-dev \
    protobuf-compiler libprotobuf-dev gnupg lsb-release libssl-dev nodejs

if [ ! -d "${ORT_SRC_DIR}" ]; then
    git clone --branch "${ORT_VERSION}" --depth 1 "${ORT_REPO}" "${ORT_SRC_DIR}"
fi
cd "${ORT_SRC_DIR}"
git submodule update --init --recursive

# Setup EMSDK
EMSDK_DIR="${ORT_SRC_DIR}/cmake/external/emsdk"
cd "${EMSDK_DIR}"
./emsdk install latest
./emsdk activate latest
source ./emsdk_env.sh
cd "${ORT_SRC_DIR}"

# -----------------------------------------------------------------------------
# 1. Native Build (Linux Shared Libs)
# -----------------------------------------------------------------------------
./build.sh --config Release --build_shared_lib --parallel "${JOBS}" \
    --allow_running_as_root --use_xnnpack --skip_tests --skip_onnx_tests

# Install native libs
if [ -d "build/Linux/Release" ]; then
    cmake --install build/Linux/Release --prefix /usr/local
fi

# -----------------------------------------------------------------------------
# 2. WebAssembly Multi-Pass Build
# -----------------------------------------------------------------------------
if [ "$(uname -m)" = "x86_64" ]; then
    mkdir -p "${WASM_OUTPUT_DIR}"
    
    # We define an explicit absolute path for WASM to avoid the 'Linux' folder mixup
    WASM_ABS_PATH="${ORT_SRC_DIR}/build_wasm_output"
    BASE_FLAGS="--build_dir ${WASM_ABS_PATH} --config Release --build_wasm --parallel ${JOBS} --allow_running_as_root --skip_tests --disable_wasm_exception_catching --disable_rtti --wasm_malloc emmalloc"

    # BUILD A: SIMD + Threads
    echo ">>> Building WASM: Standard SIMD+Threads"
    rm -rf "${WASM_ABS_PATH}"
    ./build.sh ${BASE_FLAGS} --enable_wasm_simd --enable_wasm_threads
    find "${WASM_ABS_PATH}" -type f \( -name "ort-wasm*" \) -exec cp -v {} "${WASM_OUTPUT_DIR}/" \;

    # BUILD B: JSEP (WebGPU + WebNN)
    echo ">>> Building WASM: JSEP (WebGPU/WebNN)"
    rm -rf "${WASM_ABS_PATH}"
    ./build.sh ${BASE_FLAGS} --enable_wasm_simd --enable_wasm_threads --use_jsep --use_webnn
    find "${WASM_ABS_PATH}" -type f \( -name "ort-wasm*" \) -exec cp -v {} "${WASM_OUTPUT_DIR}/" \;

    # BUILD C: Training
    echo ">>> Building WASM: Training"
    rm -rf "${WASM_ABS_PATH}"
    ./build.sh ${BASE_FLAGS} --enable_wasm_simd --enable_wasm_threads --enable_training_apis
    find "${WASM_ABS_PATH}" -type f \( -name "ort-training*" -o -name "ort-wasm*" \) -exec cp -v {} "${WASM_OUTPUT_DIR}/" \;

    echo "Final artifacts in ${WASM_OUTPUT_DIR}:"
    ls -F "${WASM_OUTPUT_DIR}"
fi

ldconfig
