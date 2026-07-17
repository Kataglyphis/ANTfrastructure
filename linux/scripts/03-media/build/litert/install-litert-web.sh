#!/usr/bin/env bash
# Vendor the prebuilt LiteRT web (WASM/JS) runtimes into the image, mirroring how
# onnxruntime-web assets are shipped for browser use. Unlike onnxruntime-web (which
# we compile from source via emscripten), these are PREBUILT npm packages, so this
# is a pinned download + extract of the servable .wasm/.js assets — arch-independent,
# so the identical output is shipped to amd64/arm64/riscv64.
#
#   LiteRT.js        : @litertjs/core (+ @litertjs/tfjs-interop, @litertjs/wasm-utils)
#                      https://developers.google.com/edge/litert/web
#   LiteRT-LM (web)  : @mediapipe/tasks-genai — Google's on-device LLM Inference API
#                      for the web (the LiteRT-LM lineage; there is no `litert-lm` npm).
#
# Outputs (served like /usr/local/lib/onnxruntime-web):
#   ${LITERT_WEB_OUTPUT_DIR:-/usr/local/lib/litert-web}      <- @litertjs assets
#   ${LITERT_LM_WEB_OUTPUT_DIR:-/usr/local/lib/litert-lm-web} <- @mediapipe/tasks-genai
set -euo pipefail

# Define logging UNCONDITIONALLY as functions: `command -v info` would otherwise
# resolve to the GNU texinfo `info` binary (present in the build image), so any
# `info "msg"` would run the manual reader and fail under `set -e`.
info() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }

LITERTJS_VERSION="${LITERTJS_VERSION:-2.5.3}"
MEDIAPIPE_GENAI_VERSION="${MEDIAPIPE_GENAI_VERSION:-0.10.29}"
LITERT_WEB_OUTPUT_DIR="${LITERT_WEB_OUTPUT_DIR:-/usr/local/lib/litert-web}"
LITERT_LM_WEB_OUTPUT_DIR="${LITERT_LM_WEB_OUTPUT_DIR:-/usr/local/lib/litert-lm-web}"
REGISTRY="${NPM_REGISTRY:-https://registry.npmjs.org}"

# Fetch <scope>/<name>@<version> from the npm registry and extract package/ into
# ${dest}. Pinned tarball URL (no npm resolver) for reproducibility; retried.
_fetch_npm_package() {
  local spec="$1" version="$2" dest="$3"
  local name="${spec##*/}" scope_path="${spec}"
  local url="${REGISTRY}/${scope_path}/-/${name}-${version}.tgz"
  local tmp; tmp="$(mktemp -d)"
  local tries=0 ok=0
  while [ "${tries}" -lt 3 ]; do
    if curl -fsSL --max-time 120 "${url}" -o "${tmp}/pkg.tgz"; then ok=1; break; fi
    tries=$((tries + 1)); warn "download ${spec}@${version} failed (try ${tries}/3)"; sleep 2
  done
  if [ "${ok}" -ne 1 ]; then rm -rf "${tmp}"; warn "giving up on ${spec}@${version}"; return 1; fi
  mkdir -p "${dest}"
  # npm tarballs unpack under a top-level `package/`; strip it.
  tar xzf "${tmp}/pkg.tgz" -C "${dest}" --strip-components=1 package/ 2>/dev/null \
    || tar xzf "${tmp}/pkg.tgz" -C "${dest}" 2>/dev/null
  rm -rf "${tmp}"
  info "vendored ${spec}@${version} -> ${dest}"
}

vendor_litertjs() {
  info "Vendoring LiteRT.js web runtime (@litertjs/core ${LITERTJS_VERSION})"
  rm -rf "${LITERT_WEB_OUTPUT_DIR}"; mkdir -p "${LITERT_WEB_OUTPUT_DIR}"
  _fetch_npm_package "@litertjs/core" "${LITERTJS_VERSION}" "${LITERT_WEB_OUTPUT_DIR}/core" || return 1
  # tfjs-interop / wasm-utils track core's version; tolerate a minor skew.
  _fetch_npm_package "@litertjs/tfjs-interop" "${LITERTJS_VERSION}" "${LITERT_WEB_OUTPUT_DIR}/tfjs-interop" || \
    warn "tfjs-interop ${LITERTJS_VERSION} unavailable; continuing (core is sufficient to serve)"
  _fetch_npm_package "@litertjs/wasm-utils" "${LITERTJS_VERSION}" "${LITERT_WEB_OUTPUT_DIR}/wasm-utils" || \
    warn "wasm-utils ${LITERTJS_VERSION} unavailable; continuing"
  # Convenience: flatten the servable wasm/loaders to the top so a static server
  # can point straight at ${LITERT_WEB_OUTPUT_DIR}/wasm/ like loadLiteRt() expects.
  if [ -d "${LITERT_WEB_OUTPUT_DIR}/core/wasm" ]; then
    ln -sfn core/wasm "${LITERT_WEB_OUTPUT_DIR}/wasm"
  fi
  [ -n "$(find "${LITERT_WEB_OUTPUT_DIR}" -name '*.wasm' -print -quit 2>/dev/null)" ] \
    || { warn "no .wasm found in ${LITERT_WEB_OUTPUT_DIR}"; return 1; }
}

vendor_litert_lm_web() {
  info "Vendoring LiteRT-LM web runtime (@mediapipe/tasks-genai ${MEDIAPIPE_GENAI_VERSION})"
  rm -rf "${LITERT_LM_WEB_OUTPUT_DIR}"; mkdir -p "${LITERT_LM_WEB_OUTPUT_DIR}"
  _fetch_npm_package "@mediapipe/tasks-genai" "${MEDIAPIPE_GENAI_VERSION}" "${LITERT_LM_WEB_OUTPUT_DIR}" || return 1
  [ -n "$(find "${LITERT_LM_WEB_OUTPUT_DIR}" -name '*.wasm' -print -quit 2>/dev/null)" ] \
    || { warn "no .wasm found in ${LITERT_LM_WEB_OUTPUT_DIR} (genai wasm expected)"; return 1; }
}

main() {
  # Always create the output dirs so the final-stage COPYs stay valid even if
  # vendoring is skipped/fails (best-effort — a registry hiccup must not break the
  # media build, and Docker COPY of a missing dir would).
  mkdir -p "${LITERT_WEB_OUTPUT_DIR}" "${LITERT_LM_WEB_OUTPUT_DIR}"
  command -v curl >/dev/null 2>&1 || { warn "curl unavailable; cannot vendor LiteRT web assets"; exit 0; }
  local rc=0
  vendor_litertjs        || { warn "LiteRT.js web vendoring failed (non-fatal)"; rc=1; }
  vendor_litert_lm_web   || { warn "LiteRT-LM web (mediapipe-genai) vendoring failed (non-fatal)"; rc=1; }
  if [ "${rc}" -eq 0 ]; then
    info "LiteRT web assets ready: ${LITERT_WEB_OUTPUT_DIR}, ${LITERT_LM_WEB_OUTPUT_DIR}"
  fi
  # Best-effort overall: a transient registry failure must not break the media build.
  exit 0
}

main "$@"
