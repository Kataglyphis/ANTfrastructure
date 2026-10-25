#!/usr/bin/env bash
# A partial tar extraction must never count as a cached Node installation.

node_toolchain_valid() {
  local candidate="$1" match="$2" directory version
  directory="$(dirname "${candidate}")"
  [ -x "${candidate}" ] && [ -x "${directory}/npm" ] || return 1
  version="$("${candidate}" --version 2>/dev/null)" || return 1
  rb_py node-version "${match}" "${version}" "${RENOVATE_NODE_VERSION}" || return 1
  PATH="${directory}:${PATH}" "${directory}/npm" --version >/dev/null 2>&1
}

# arch_normalize owns the arch spelling; a local `uname -m` case is what the dupes gate flags.
node_arch_asset() {
  local arch
  arch="$(arch_normalize "$(uname -m)")"
  case "${arch}" in
    amd64) printf 'linux-x64 %s\n'   "${RENOVATE_NODE_LINUX_X64_SHA256:-}" ;;
    arm64) printf 'linux-arm64 %s\n' "${RENOVATE_NODE_LINUX_ARM64_SHA256:-}" ;;
    *) err "no pinned Node asset for ${arch}; install Node ${RENOVATE_NODE_VERSION}+ yourself and re-run" ;;
  esac
}

node_stage_publish() {
  local asset sha url stage got
  read -r asset sha <<<"$(node_arch_asset)"
  [ -n "${sha}" ] || err "no SHA256 pinned for node-v${RENOVATE_NODE_VERSION}-${asset}"
  url="https://nodejs.org/dist/v${RENOVATE_NODE_VERSION}/node-v${RENOVATE_NODE_VERSION}-${asset}.tar.xz"
  stage="$(mktemp -d "${CACHE_ROOT}/.node-install.XXXXXXXX")" || err "cannot stage Node install"

  note "bootstrapping node ${RENOVATE_NODE_VERSION} (${asset}) into ${NODE_DIR}" >&2
  curl -fsSL -o "${stage}/node.tar.xz" "${url}" \
    || bootstrap_stage_error "${stage}" "download failed: ${url}"
  got="$(sha256sum "${stage}/node.tar.xz" | cut -d' ' -f1)"
  if [ "${got}" != "${sha}" ]; then
    bootstrap_stage_error "${stage}" "checksum mismatch for node-v${RENOVATE_NODE_VERSION}-${asset}: expected ${sha}, got ${got}"
  fi
  mkdir -p "${stage}/tree" || bootstrap_stage_error "${stage}" "cannot stage Node tree"
  tar -xJf "${stage}/node.tar.xz" -C "${stage}/tree" --strip-components=1 \
    || bootstrap_stage_error "${stage}" "extract failed"
  node_toolchain_valid "${stage}/tree/bin/node" exact \
    || bootstrap_stage_error "${stage}" "extracted Node/npm failed their version smoke"
  rm -rf -- "${NODE_DIR}" || bootstrap_stage_error "${stage}" "cannot replace ${NODE_DIR}"
  mv -- "${stage}/tree" "${NODE_DIR}" \
    || bootstrap_stage_error "${stage}" "cannot publish ${NODE_DIR}"
  rm -rf -- "${stage}" || err "cannot clean ${stage}"
  node_toolchain_valid "${NODE_BIN}" exact || err "published Node/npm failed their version smoke"
}

bootstrap_node() {
  local path_node
  path_node="$(command -v node || true)"
  # A matching major below Renovate's minimum still fails npm's engine gate.
  if [ -n "${path_node}" ] && node_toolchain_valid "${path_node}" at-least; then
    NODE_BIN="${path_node}"
    return 0
  fi
  NODE_BIN="${NODE_DIR}/bin/node"
  bootstrap_cache_lock "${NODE_DIR}"
  if node_toolchain_valid "${NODE_BIN}" exact; then bootstrap_cache_unlock; return 0; fi
  node_stage_publish
  bootstrap_cache_unlock
}
