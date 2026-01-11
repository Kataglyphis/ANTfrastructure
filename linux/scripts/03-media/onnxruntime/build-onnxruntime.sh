#!/usr/bin/env bash
set -euxo pipefail

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
ORT_VERSION="${ORT_VERSION:-v1.23.2}"
ORT_REPO="${ORT_REPO:-https://github.com/microsoft/onnxruntime.git}"
ORT_SRC_DIR="${ORT_SRC_DIR:-/opt/onnxruntime}"
PER_JOB_MB="${ORT_PER_JOB_MB:-1500}"
REQUIRED_NODE_MAJOR="${REQUIRED_NODE_MAJOR:-18}"

# -----------------------------------------------------------------------------
# Compute JOBS (CPU + memory aware)
# -----------------------------------------------------------------------------
if [ -z "${JOBS:-}" ]; then
  CORES="$(nproc --all)"
  AVAIL_MB="$(awk '/MemAvailable/ {printf("%d",$2/1024); exit}' /proc/meminfo || true)"
  [ -z "${AVAIL_MB}" ] && AVAIL_MB=2048

  MAX_BY_MEM=$(( AVAIL_MB / PER_JOB_MB ))
  [ "${MAX_BY_MEM}" -lt 1 ] && MAX_BY_MEM=1
  JOBS=$(( CORES < MAX_BY_MEM ? CORES : MAX_BY_MEM ))
  [ "${JOBS}" -gt 1 ] && JOBS=$((JOBS - 1))
  [ "${JOBS}" -lt 1 ] && JOBS=1
fi

export JOBS
export CMAKE_BUILD_PARALLEL_LEVEL="${JOBS}"
export MAKEFLAGS="-j${JOBS}"

echo "Using JOBS=${JOBS}"

# -----------------------------------------------------------------------------
# System dependencies
# -----------------------------------------------------------------------------
DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  git ca-certificates curl wget build-essential pkg-config \
  python3 python3-dev cmake ninja-build zlib1g-dev \
  protobuf-compiler libprotobuf-dev gnupg lsb-release

# -----------------------------------------------------------------------------
# Node.js check
# -----------------------------------------------------------------------------
NODE_MAJOR=0
if command -v node >/dev/null 2>&1; then
  NODE_MAJOR="$(node -v | sed 's/^v//' | cut -d. -f1)"
  echo "Detected node $(node -v)"
fi

if [ "${NODE_MAJOR}" -lt "${REQUIRED_NODE_MAJOR}" ]; then
  echo "Installing Node ${REQUIRED_NODE_MAJOR}.x"
  curl -fsSL "https://deb.nodesource.com/setup_${REQUIRED_NODE_MAJOR}.x" | bash -
  apt-get install -y --no-install-recommends nodejs
else
  echo "Node is sufficient, skipping installation"
fi

# -----------------------------------------------------------------------------
# Clone ONNX Runtime
# -----------------------------------------------------------------------------
rm -rf "${ORT_SRC_DIR}"
git clone --branch "${ORT_VERSION}" --depth 1 "${ORT_REPO}" "${ORT_SRC_DIR}"
cd "${ORT_SRC_DIR}"
git submodule update --init --recursive

# -----------------------------------------------------------------------------
# EMSDK Setup
# -----------------------------------------------------------------------------
EMSDK_DIR="${ORT_SRC_DIR}/cmake/external/emsdk"
cd "${EMSDK_DIR}"
./emsdk install latest
./emsdk activate latest
# shellcheck disable=SC1091
source ./emsdk_env.sh
cd "${ORT_SRC_DIR}"

# -----------------------------------------------------------------------------
# Native build (Linux)
# -----------------------------------------------------------------------------
./build.sh \
  --config Release \
  --build_shared_lib \
  --parallel "${JOBS}" \
  --allow_running_as_root \
  --use_xnnpack \
  --skip_tests \
  --skip_onnx_tests

if [ -d "build/Linux/Release" ]; then
  cmake --install build/Linux/Release --prefix /usr/local
fi

# -----------------------------------------------------------------------------
# WebAssembly build (SIMD + threads)
# -----------------------------------------------------------------------------
if [ "$(uname -m)" = "x86_64" ]; then
  # We use a distinct build directory to prevent path collisions
  WASM_BUILD_DIR="build/Wasm"
  rm -rf "${WASM_BUILD_DIR}"

  ./build.sh \
    --build_dir "${WASM_BUILD_DIR}" \
    --config Release \
    --build_wasm \
    --parallel "${JOBS}" \
    --allow_running_as_root \
    --skip_tests \
    --disable_wasm_exception_catching \
    --disable_rtti \
    --enable_wasm_simd \
    --enable_wasm_threads

  WASM_OUTPUT_DIR="/usr/local/lib/onnxruntime-web"
  mkdir -p "${WASM_OUTPUT_DIR}"

  echo "Collecting WASM artifacts from ${WASM_BUILD_DIR}..."
  # Use find on the specific WASM build directory we defined
  if [ -d "${WASM_BUILD_DIR}" ]; then
    find "${WASM_BUILD_DIR}" -type f \( \
      -name "ort-*.wasm" -o \
      -name "ort-*.js" -o \
      -name "ort-*.mjs" -o \
      -name "*.worker.js" \
    \) -exec cp -v {} "${WASM_OUTPUT_DIR}/" \;
  else
    echo "ERROR: WASM build directory ${WASM_BUILD_DIR} was not created!"
    exit 1
  fi

  # Final check
  if [ -f "${WASM_OUTPUT_DIR}/ort-wasm-simd-threaded.wasm" ]; then
    echo "WASM artifacts successfully installed to ${WASM_OUTPUT_DIR}"
  else
    echo "ERROR: Critical WASM files are missing from ${WASM_OUTPUT_DIR}"
    exit 1
  fi
else
  echo "Skipping WASM build (non-x86_64)"
fi

ldconfig
echo "ONNX Runtime build finished successfully"
