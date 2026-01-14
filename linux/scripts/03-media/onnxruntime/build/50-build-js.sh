#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

parse_common_args "$@"
detect_jobs

if ! is_amd64_arch; then
	info "Skipping JS/web build on non-amd64 architecture (arch=$(detect_target_arch))"
	exit 0
fi

cd "${ORT_SRC_DIR}"

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

info "JS build finished. Artifacts in ${WASM_OUTPUT_DIR}"
ls -F "${WASM_OUTPUT_DIR}" || true
