#!/usr/bin/env bash
set -euo pipefail

# verify-cross-chain.sh
#
# Standalone cross-chain staleness verification.  Resolves registry digests for
# every stage transition in the cross lane and reports whether downstream images
# may be stale relative to their declared parent.
#
# This is a thin wrapper around the verify_chain() logic in build-cross-chain.sh,
# shared via the stage graph (stage-defs.sh) and digest-pinning infrastructure.
#
# Usage:
#   bash linux/scripts/verify-cross-chain.sh --target-arches amd64,arm64,riscv64
#   bash linux/scripts/verify-cross-chain.sh --target-arches arm64
#   bash linux/scripts/verify-cross-chain.sh --target-arches amd64,arm64,riscv64 --image-repo ghcr.io/myorg/kataglyphis_beschleuniger

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck disable=SC1091
source "${REPO_ROOT}/linux/scripts/01-core/artifact-common.sh"

NERDCTL_BIN="${NERDCTL_BIN:-nerdctl}"
IMAGE_REPO="${IMAGE_REPO:-${IMAGE_REGISTRY_PREFIX}}"
TARGET_ARCHES="${TARGET_ARCHES:-${TARGET_ARCH:-${CROSS_DEFAULT_ARCHES}}}"

usage() {
  cat <<'EOF'
Usage: verify-cross-chain.sh [options]

Resolve registry digests for every cross-lane stage transition and report
whether downstream images may be stale relative to their parent.  No builds
are performed.

Options:
  --target-arches LIST     Comma-separated arch list (default: amd64,arm64,riscv64)
  --architectures LIST     Alias for --target-arches
  --image-repo REPO        Image repository (default: ghcr.io/kataglyphis/kataglyphis_beschleuniger)
  -h, --help               Show this help text
EOF
}

# ── Chain verification (shared logic from build-cross-chain.sh) ───────────────

_verify_link() {
  local label="$1" parent_tag="$2" child_tag="$3" parent_digest child_base_digest
  parent_digest="$(registry_pin_ref "${NERDCTL_BIN}" "${parent_tag}" 2>/dev/null || true)"
  if [ -z "${parent_digest}" ]; then
    warn "[verify] ${label}: parent tag ${parent_tag} not resolvable in registry"
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    warn "[verify] ${label}: python3 not available, skipping base layer check"
    return 0
  fi
  child_base_digest="$("${NERDCTL_BIN}" manifest inspect "${child_tag}" 2>/dev/null \
    | python3 "${REPO_ROOT}/linux/scripts/01-core/manifest-base-layer.py" 2>/dev/null || true)"
  if [ -n "${child_base_digest}" ]; then
    log "[verify] ${label}: parent ${parent_digest}"
    log "[verify] ${label}: child  ${child_tag}"
    log "[verify] ${label}: child base layer ${child_base_digest}"
  else
    log "[verify] ${label}: parent digest ${parent_digest} (child tag unresolvable)"
  fi
}

verify_chain() {
  local stage parent parent_tag child_tag arch label

  log "[verify] checking cross-chain freshness for arches: ${TARGET_ARCHES}"

  for stage in "${CROSS_STAGE_ORDER[@]}"; do
    [ "${stage}" = "base" ] && continue    # no parent to verify
    [ "${stage}" = "runtime" ] && continue # delegates to runtime helper, not a cross stage

    parent="$(cross_stage_parent "${stage}")"

    if cross_stage_is_per_arch "${stage}"; then
      for arch in ${TARGET_ARCHES//,/ }; do
        if cross_stage_is_per_arch "${parent}"; then
          parent_tag="$(cross_stage_tag "${parent}" "${arch}")"
        else
          parent_tag="$(cross_stage_tag "${parent}")"
        fi
        child_tag="$(cross_stage_tag "${stage}" "${arch}")"
        label="${parent}->${stage}-${arch}"
        _verify_link "${label}" "${parent_tag}" "${child_tag}"
      done
    else
      parent_tag="$(cross_stage_tag "${parent}")"
      child_tag="$(cross_stage_tag "${stage}")"
      label="${parent}->${stage}"
      _verify_link "${label}" "${parent_tag}" "${child_tag}"
    fi
  done

  log "[verify] chain check complete"
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
  while [ $# -gt 0 ]; do
    local _dispatch_rc=0
    dispatch_parsed_args parse_shared_orchestrator_args \
      TARGET_ARCHES _unused_mirror _unused_mirror_url \
      _unused_ports_url IMAGE_REPO _unused_vulkan _unused_push \
      "$1" "${2:-}" || _dispatch_rc=$?
    case $_dispatch_rc in
      255) usage; exit 0 ;;
      0) case "${_DP_SHIFT}" in
           1) shift 1; continue ;;
           2) shift 2; continue ;;
         esac ;;
    esac
    case "$1" in
      *) err "Unknown option: $1" ;;
    esac
  done

  cd "${REPO_ROOT}"
  TARGET_ARCHES="$(normalize_target_arches "${TARGET_ARCHES}")"

  verify_chain
}

main "$@"
