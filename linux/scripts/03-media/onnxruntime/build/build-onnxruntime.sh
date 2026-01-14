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
WASM_CONFIG="${WASM_CONFIG:-Release}"
NATIVE_CPU_BUILD_DIR="${NATIVE_CPU_BUILD_DIR:-${ORT_SRC_DIR}/build_native_cpu}"
NATIVE_CPU_OUTPUT_DIR="${NATIVE_CPU_OUTPUT_DIR:-/usr/local/lib/onnxruntime-cpu}"
NATIVE_CPU_CONFIG="${NATIVE_CPU_CONFIG:-Release}"
BUILD_NATIVE_CPU="${BUILD_NATIVE_CPU:-true}"
BUILD_DNNL_EP="${BUILD_DNNL_EP:-true}"
BUILD_XNNPACK_EP="${BUILD_XNNPACK_EP:-true}"
BUILD_ACL_EP="${BUILD_ACL_EP:-false}"
ACL_HOME="${ACL_HOME:-}"
ACL_LIBS="${ACL_LIBS:-}"
USE_UV_VENV="${USE_UV_VENV:-true}"
UV_VENV_DIR="${UV_VENV_DIR:-${ORT_SRC_DIR}/.venv}"
CMAKE_POLICY_VERSION_MINIMUM="${CMAKE_POLICY_VERSION_MINIMUM:-3.5}"
SKIP_DEP_INSTALL="${SKIP_DEP_INSTALL:-false}"
ENABLE_ASYNCIFY="${ENABLE_ASYNCIFY:-false}"
ASYNCIFY_STACK_SIZE="${ASYNCIFY_STACK_SIZE:-5242880}"

info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*"; exit 1; }

patch_project_dnnl_cmake_policy_minimum() {
  # CMake 4.x removed compatibility with very old cmake_minimum_required(<3.5).
  #!/usr/bin/env bash
  set -euo pipefail
  IFS=$'\n\t'

  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/lib/common.sh"

  parse_common_args "$@"

  info "Running ONNX Runtime build pipeline (monolithic wrapper)"

  bash "${SCRIPT_DIR}/10-deps.sh" "$@"
  bash "${SCRIPT_DIR}/20-fetch.sh" "$@"
  bash "${SCRIPT_DIR}/30-build-native.sh" "$@"

  if is_amd64_arch; then
    bash "${SCRIPT_DIR}/40-build-wasm.sh" "$@"
    bash "${SCRIPT_DIR}/50-build-js.sh" "$@"
  else
    info "Skipping all web builds (WASM/JS) on non-amd64 architecture (arch=$(detect_target_arch))"
  fi

  info "Complete build finished. Artifacts in ${WASM_OUTPUT_DIR}"
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
