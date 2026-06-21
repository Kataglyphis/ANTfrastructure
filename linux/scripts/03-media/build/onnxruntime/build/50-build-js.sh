#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

parse_common_args "$@"
detect_jobs

patch_web_build_targets() {
  local skip_webgpu="$1"
  local skip_jspi="$2"
  local build_script="${ORT_SRC_DIR}/js/web/script/build.ts"

  [ "${skip_webgpu}" = "false" ] && [ "${skip_jspi}" = "false" ] && return 0

  if [ ! -f "${build_script}" ]; then
    warn "onnxruntime-web build script not found at ${build_script}; keeping upstream bundle list"
    return 0
  fi

  info "Adjusting onnxruntime-web targets to match staged WASM variants"
  if ! SKIP_WEBGPU="${skip_webgpu}" SKIP_JSPI="${skip_jspi}" BUILD_SCRIPT="${build_script}" node <<'EOF'
const fs = require('node:fs');

const buildScript = process.env.BUILD_SCRIPT;
let source = fs.readFileSync(buildScript, 'utf8');

const removeSection = (text, startMarker, endMarker, replacement) => {
  const start = text.indexOf(startMarker);
  if (start === -1) {
    throw new Error(`Start marker not found: ${startMarker}`);
  }

  const end = text.indexOf(endMarker, start);
  if (end === -1) {
    throw new Error(`End marker not found after ${startMarker}: ${endMarker}`);
  }

  return text.slice(0, start) + replacement + text.slice(end);
};

if (process.env.SKIP_WEBGPU === 'true') {
  source = removeSection(
    source,
    '    // ort.webgpu[.min].[m]js',
    '    // ort.jspi[.min].[m]js',
    '    // ort.webgpu outputs skipped: asyncify WASM artifacts are unavailable.\n',
  );
}

if (process.env.SKIP_JSPI === 'true') {
  source = removeSection(
    source,
    '    // ort.jspi[.min].[m]js',
    '    // ort.wasm[.min].[m]js',
    '    // ort.jspi outputs skipped: JSPI WASM artifacts are unavailable.\n',
  );
}

fs.writeFileSync(buildScript, source);
EOF
  then
    warn "Failed to trim unsupported onnxruntime-web targets; proceeding with upstream build"
  fi
}

if ! is_amd64_arch; then
	info "Skipping JS/web build on non-amd64 architecture (arch=$(detect_target_arch))"
	exit 0
fi

cd "${ORT_SRC_DIR}"

info ">>> Building onnxruntime-web JS packages"
mkdir -p "${ORT_SRC_DIR}/js/web/dist"
cp -v "${WASM_OUTPUT_DIR}"/* "${ORT_SRC_DIR}/js/web/dist/" || true

skip_webgpu=false
skip_jspi=false

if [ ! -f "${ORT_SRC_DIR}/js/web/dist/ort-wasm-simd-threaded.asyncify.mjs" ] || \
   [ ! -f "${ORT_SRC_DIR}/js/web/dist/ort-wasm-simd-threaded.asyncify.wasm" ]; then
  skip_webgpu=true
  warn "Skipping ort.webgpu JS outputs: asyncify WASM artifacts are unavailable"
  rm -f "${ORT_SRC_DIR}/js/web/dist"/ort.webgpu* "${WASM_OUTPUT_DIR}"/ort.webgpu* || true
fi

if [ ! -f "${ORT_SRC_DIR}/js/web/dist/ort-wasm-simd-threaded.jspi.mjs" ] || \
   [ ! -f "${ORT_SRC_DIR}/js/web/dist/ort-wasm-simd-threaded.jspi.wasm" ]; then
  skip_jspi=true
  warn "Skipping ort.jspi JS outputs: JSPI WASM artifacts are unavailable"
  rm -f "${ORT_SRC_DIR}/js/web/dist"/ort.jspi* "${WASM_OUTPUT_DIR}"/ort.jspi* || true
fi

cd "${ORT_SRC_DIR}/js"
if ! npm ci 2>/dev/null; then
  warn "npm ci failed, trying npm install"
  npm install || err "npm install failed in js/"
fi

cd "${ORT_SRC_DIR}/js/common"
if ! npm ci 2>/dev/null; then
  warn "npm ci failed in common/, trying npm install"
  npm install || err "npm install failed in js/common/"
fi

patch_web_build_targets "${skip_webgpu}" "${skip_jspi}"

cd "${ORT_SRC_DIR}/js/web"
if ! npm ci 2>/dev/null; then
  warn "npm ci failed in web/, trying npm install"
  npm install || err "npm install failed in js/web/"
fi
npm run build || err "npm run build failed in js/web/"

# Validate JS build produced output
if ! ls "${ORT_SRC_DIR}/js/web/dist"/*.js >/dev/null 2>&1 && ! ls "${ORT_SRC_DIR}/js/web/dist"/*.mjs >/dev/null 2>&1; then
  err "No .js or .mjs files found in js/web/dist/ after build"
fi

cp -v "${ORT_SRC_DIR}/js/web/dist"/*.js "${WASM_OUTPUT_DIR}/" || true
cp -v "${ORT_SRC_DIR}/js/web/dist"/*.mjs "${WASM_OUTPUT_DIR}/" || true

rm -rf "${ORT_SRC_DIR}/js/node_modules" \
	"${ORT_SRC_DIR}/js/common/node_modules" \
	"${ORT_SRC_DIR}/js/web/node_modules" \
	/root/.npm \
	/root/.cache/npm || true

info "JS build finished. Artifacts in ${WASM_OUTPUT_DIR}"
ls -F "${WASM_OUTPUT_DIR}" || true
