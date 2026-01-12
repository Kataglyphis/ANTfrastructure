#!/usr/bin/env bash
# build-onnxruntime.sh  (corrected with allow_running_as_root)
set -euo pipefail
IFS=$'\n\t'

# ----------------------------
# Config
# ----------------------------
ORT_VERSION="${ORT_VERSION:-v1.23.2}"
ORT_REPO="${ORT_REPO:-https://github.com/microsoft/onnxruntime.git}"
ORT_SRC_DIR="${ORT_SRC_DIR:-/opt/onnxruntime}"
WASM_OUTPUT_DIR="${WASM_OUTPUT_DIR:-/usr/local/lib/onnxruntime-web}"
BUILD_DIR="${BUILD_DIR:-${ORT_SRC_DIR}/build_wasm_output}"
SKIP_DEP_INSTALL="${SKIP_DEP_INSTALL:-false}"
ENABLE_ASYNCIFY="${ENABLE_ASYNCIFY:-false}"
ASYNCIFY_STACK_SIZE="${ASYNCIFY_STACK_SIZE:-5242880}"

info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*"; exit 1; }

# Determine JOBS (parallelism)
if [ -z "${JOBS:-}" ]; then
  CORES="$(nproc --all || echo 1)"
  AVAIL_MB="$(awk '/MemAvailable/ {printf("%d",$2/1024); exit}' /proc/meminfo || true)"
  [ -z "${AVAIL_MB}" ] && AVAIL_MB=2048
  MAX_BY_MEM=$(( AVAIL_MB / 2000 ))
  JOBS=$(( CORES < MAX_BY_MEM ? CORES : MAX_BY_MEM ))
  [ "${JOBS}" -lt 1 ] && JOBS=1
fi
export JOBS
info "Using JOBS=${JOBS}"

# ----------------------------
# Install system deps (Debian/Ubuntu)
# ----------------------------
if [ "${SKIP_DEP_INSTALL}" != "true" ]; then
  info "Installing OS packages (apt-get)..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y

  apt-get install -y --no-install-recommends \
    git ca-certificates curl wget build-essential pkg-config \
    python3 python3-dev python3-pip cmake ninja-build zlib1g-dev \
    protobuf-compiler libprotobuf-dev gnupg lsb-release libssl-dev \
    nodejs

  # Pip utilities
  pip3 install --no-cache-dir ninja || true
fi

# Verify npm exists; if not, install npm via official npm installer
if ! command -v npm >/dev/null 2>&1; then
  warn "npm not found after installing nodejs. Installing npm via official installer..."
  curl -qL https://www.npmjs.com/install.sh | sh
  if ! command -v npm >/dev/null 2>&1; then
    err "npm install fallback failed — npm not available. Consider installing node via NodeSource or nvm."
  fi
fi
info "node: $(node -v || true), npm: $(npm -v || true)"

# ----------------------------
# Clone repo and submodules
# ----------------------------
if [ ! -d "${ORT_SRC_DIR}" ]; then
  info "Cloning ONNX Runtime ${ORT_VERSION} into ${ORT_SRC_DIR}"
  git clone --branch "${ORT_VERSION}" --depth 1 "${ORT_REPO}" "${ORT_SRC_DIR}"
fi
cd "${ORT_SRC_DIR}"
git submodule sync --recursive || true
git submodule update --init --recursive

# ----------------------------
# Setup emsdk (if present in repo)
# ----------------------------
EMSDK_DIR="${ORT_SRC_DIR}/cmake/external/emsdk"
if [ -d "${EMSDK_DIR}" ]; then
  info "Setting up emsdk at ${EMSDK_DIR}"
  cd "${EMSDK_DIR}"
  if [ -f "emsdk_version.txt" ]; then
    EMSDK_VERSION="$(cat emsdk_version.txt)"
    ./emsdk install "${EMSDK_VERSION}" || ./emsdk install "${EMSDK_VERSION}"
    ./emsdk activate "${EMSDK_VERSION}"
  else
    ./emsdk install latest || true
    ./emsdk activate latest || true
  fi
  # shellcheck disable=SC1091
  source ./emsdk_env.sh || true
  cd "${ORT_SRC_DIR}"
else
  warn "emsdk directory not found at ${EMSDK_DIR}; WASM builds will fail without emsdk."
fi

# Build wrapper path
BUILD_SH="${ORT_SRC_DIR}/build.sh"
[ -x "${BUILD_SH}" ] || err "build.sh not found or not executable at ${BUILD_SH}"

# Define common arguments as an array
COMMON_ARGS=(
  "--build_dir" "${BUILD_DIR}"
  "--config" "Release"
  "--build_wasm"
  "--parallel" "${JOBS}"
  "--skip_tests"
  "--disable_wasm_exception_catching"
  "--disable_rtti"
  "--allow_running_as_root"
)

mkdir -p "${WASM_OUTPUT_DIR}"
rm -rf "${BUILD_DIR}" || true

# Optional: enable Asyncify by setting EMCC flags
if [ "${ENABLE_ASYNCIFY}" = "true" ]; then
  info "Enabling Asyncify via EMCC flags (ASYNCIFY_STACK_SIZE=${ASYNCIFY_STACK_SIZE})"
  export EMCC_CFLAGS="-s ASYNCIFY=1 -s ASYNCIFY_STACK_SIZE=${ASYNCIFY_STACK_SIZE}"
  export EMCC_LINKER_FLAGS="${EMCC_CFLAGS}"
fi

# ----------------------------
# Build passes (per ONNX Runtime docs)
# ----------------------------
info ">>> Pass 1: SIMD + Threads"
rm -rf "${BUILD_DIR}"
"${BUILD_SH}" "${COMMON_ARGS[@]}" --enable_wasm_simd --enable_wasm_threads
find "${BUILD_DIR}/Release" -type f -name "ort-wasm-simd-threaded.*" -exec cp -v '{}' "${WASM_OUTPUT_DIR}/" ';' || true

info ">>> Pass 2: JSEP (WebGPU/WebNN)"
rm -rf "${BUILD_DIR}"
"${BUILD_SH}" "${COMMON_ARGS[@]}" --enable_wasm_simd --enable_wasm_threads --use_jsep --use_webnn
find "${BUILD_DIR}/Release" -type f \( -name "ort-wasm-simd-threaded.jsep.*" -o -name "ort-wasm-simd-threaded.webnn.*" \) -exec cp -v '{}' "${WASM_OUTPUT_DIR}/" ';' || true

info ">>> Pass 3: Training APIs"
rm -rf "${BUILD_DIR}"
"${BUILD_SH}" "${COMMON_ARGS[@]}" --enable_wasm_simd --enable_wasm_threads --enable_training_apis
find "${BUILD_DIR}/Release" -type f -name "ort-training*" -exec cp -v '{}' "${WASM_OUTPUT_DIR}/" ';' || true

# Optional Asyncify-pass copy (if you produced a special artifact)
if [ "${ENABLE_ASYNCIFY}" = "true" ]; then
  info ">>> Pass 4: Asyncify-marked (copied if present)"
  rm -rf "${BUILD_DIR}"
  "${BUILD_SH}" "${COMMON_ARGS[@]}" --enable_wasm_simd --enable_wasm_threads
  find "${BUILD_DIR}/Release" -type f \( -name "ort-wasm-simd-threaded.asyncify.*" -o -name "ort-wasm-simd-threaded.*" \) -exec cp -v '{}' "${WASM_OUTPUT_DIR}/" ';' || true
fi

info "WASM artifacts in ${WASM_OUTPUT_DIR}"
ls -alh "${WASM_OUTPUT_DIR}" || true

# ----------------------------
# Build JS package (onnxruntime-web)
# ----------------------------
info ">>> Building onnxruntime-web JS packages"
mkdir -p "${ORT_SRC_DIR}/js/web/dist"
cp -v "${WASM_OUTPUT_DIR}"/* "${ORT_SRC_DIR}/js/web/dist/" || true

cd "${ORT_SRC_DIR}/js"
npm ci || npm install || true
cd "${ORT_SRC_DIR}/js/common"
npm ci || npm install || true
cd "${ORT_SRC_DIR}/js/web"
npm ci || npm install || true
npm run build || true

cp -v "${ORT_SRC_DIR}/js/web/dist"/*.js "${WASM_OUTPUT_DIR}/" || true
cp -v "${ORT_SRC_DIR}/js/web/dist"/*.mjs "${WASM_OUTPUT_DIR}/" || true

info "Complete build finished. Artifacts: "
ls -F "${WASM_OUTPUT_DIR}" || true
exit 0
