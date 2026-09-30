#!/usr/bin/env bash
# Prebuilt, arch-independent npm assets; LiteRT-LM's web runtime is @mediapipe/tasks-genai, as no litert-lm npm exists.
set -euo pipefail

# Defined unconditionally: `command -v info` would find texinfo's info binary in the build image.
info() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }

LITERTJS_VERSION="${LITERTJS_VERSION:-2.5.3}"
MEDIAPIPE_GENAI_VERSION="${MEDIAPIPE_GENAI_VERSION:-0.10.29}"
LITERT_WEB_OUTPUT_DIR="${LITERT_WEB_OUTPUT_DIR:-/usr/local/lib/litert-web}"
LITERT_LM_WEB_OUTPUT_DIR="${LITERT_LM_WEB_OUTPUT_DIR:-/usr/local/lib/litert-lm-web}"
REGISTRY="${NPM_REGISTRY:-https://registry.npmjs.org}"

# A pinned tarball URL rather than the npm resolver, for reproducibility.
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
  # The tarball comes from the CDN, so check it against the registry's dist.integrity; no metadata only warns.
  local _want_int _got_int
  _want_int="$(curl -fsSL --max-time 30 "${REGISTRY}/${scope_path}/${version}" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("dist",{}).get("integrity",""))' 2>/dev/null || true)"
  if [ -n "${_want_int}" ]; then
    _got_int="sha512-$(python3 -c 'import hashlib,base64,sys; print(base64.b64encode(hashlib.sha512(open(sys.argv[1],"rb").read()).digest()).decode())' "${tmp}/pkg.tgz" 2>/dev/null)"
    if [ "${_want_int}" != "${_got_int}" ]; then
      rm -rf "${tmp}"
      warn "INTEGRITY MISMATCH ${spec}@${version}: registry ${_want_int} != downloaded ${_got_int} — refusing (tampering/corruption)"
      return 1
    fi
    info "integrity verified ${spec}@${version} (sha512)"
  else
    warn "could not fetch dist.integrity for ${spec}@${version} — proceeding WITHOUT integrity verification"
  fi
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
  # loadLiteRt() expects the wasm directly under ${LITERT_WEB_OUTPUT_DIR}/wasm/.
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
  # Always create them: the final-stage COPYs fail on a missing dir even when vendoring is skipped.
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
