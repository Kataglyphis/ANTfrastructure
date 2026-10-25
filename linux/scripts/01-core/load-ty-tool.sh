#!/usr/bin/env bash
# Shared setup keeps pinned ty identical in preflight and image builds.

load_ty_tool() {
  local pins="${1:?tool pin file required}"
  [ -f "${pins}" ] || { echo "ty tool pins are missing at ${pins}" >&2; return 2; }
  # shellcheck source=load-versions-env.sh
  source "$(dirname "${BASH_SOURCE[0]}")/load-versions-env.sh" || return 1
  unset TY_VERSION
  load_versions_env "${pins}" || return 1
  : "${TY_VERSION:?TY_VERSION is missing from tool-pins.env}"
  command -v uvx >/dev/null 2>&1 || { echo "uvx is required for ty@${TY_VERSION}" >&2; return 2; }
}
