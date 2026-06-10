#!/usr/bin/env bash
# chain-verify.sh — cross-chain staleness verification shared by orchestrator
# and standalone verify script.
#
# Source this directly or through artifact-common.sh.
# Depends on: stage-defs.sh, digest-pinning.sh, logging.sh, tag-naming.sh.
[ -n "${_CHAIN_VERIFY_SH_LOADED:-}" ] && return 0
_CHAIN_VERIFY_SH_LOADED=1
#
# Provides:
#   _verify_link()                  — check one parent→child transition
#   verify_cross_chain_staleness()  — verify every cross-lane stage transition
#   describe_cross_chain()          — print the full stage graph with tag names

# ==============================================================================
# _verify_link
#
# Verify one parent→child stage transition by resolving registry digests.
# Reports the parent digest, child tag, and child's base layer digest for
# manual inspection.  Returns 0 even when unresolvable (non-fatal).
#
# Usage: _verify_link "compiler->sdk-arm64" "${parent_tag}" "${child_tag}"
# ==============================================================================
_verify_link() {
  local label="$1" parent_tag="$2" child_tag="$3" parent_digest child_base_digest

  parent_digest="$(registry_pin_ref "${NERDCTL_BIN:-nerdctl}" "${parent_tag}" 2>/dev/null || true)"
  if [ -z "${parent_digest}" ]; then
    warn "[verify] ${label}: parent tag ${parent_tag} not resolvable in registry"
    return 0
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    warn "[verify] ${label}: python3 not available, skipping base layer check"
    return 0
  fi

  child_base_digest="$("${NERDCTL_BIN:-nerdctl}" manifest inspect "${child_tag}" 2>/dev/null \
    | python3 "${_CHAIN_VERIFY_DIR:-${_ARTIFACT_COMMON_DIR}}/manifest-base-layer.py" 2>/dev/null || true)"

  if [ -n "${child_base_digest}" ]; then
    log "[verify] ${label}: parent ${parent_digest}"
    log "[verify] ${label}: child  ${child_tag}"
    log "[verify] ${label}: child base layer ${child_base_digest}"
  else
    log "[verify] ${label}: parent digest ${parent_digest} (child tag unresolvable)"
  fi
}

# ==============================================================================
# verify_cross_chain_staleness
#
# Verify every stage transition in the cross lane by checking whether downstream
# registry images are stale relative to their parent.  Uses CROSS_STAGE_ORDER
# from stage-defs.sh — no hardcoded transitions.
#
# Skips base (no parent) and runtime (delegates to separate script).
#
# Usage: verify_cross_chain_staleness "${TARGET_ARCHES}"
# ==============================================================================
verify_cross_chain_staleness() {
  local arches_csv="$1"
  local stage parent parent_tag child_tag arch label

  log "[verify] checking cross-chain freshness for arches: ${arches_csv}"

  for stage in "${CROSS_STAGE_ORDER[@]}"; do
    [ "${stage}" = "base" ] && continue    # no parent to verify
    [ "${stage}" = "runtime" ] && continue # delegates to runtime helper, not a cross stage

    parent="$(cross_stage_parent "${stage}")"

    if cross_stage_is_per_arch "${stage}"; then
      for arch in $(arch_list_to_words "${arches_csv}"); do
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

# ==============================================================================
# describe_cross_chain
#
# Print the full stage graph with tag names, parent chains, and per-arch status.
# Useful for understanding the build topology before running commands.
#
# Usage: describe_cross_chain "${TARGET_ARCHES}"
# ==============================================================================
describe_cross_chain() {
  local arches_csv="$1"
  local stage parent dockerfile tag

  printf '\nCross-lane stage chain (arches: %s)\n' "${arches_csv}"
  printf '========================================\n'

  for stage in "${CROSS_STAGE_ORDER[@]}"; do
    parent="$(cross_stage_parent "${stage}")"
    dockerfile="$(cross_stage_dockerfile "${stage}" 2>/dev/null || printf 'N/A')"

    if cross_stage_is_per_arch "${stage}"; then
      printf '\n[%s]  ← %s\n' "${stage}" "${parent:-ubuntu:26.04}"
      printf '  Dockerfile: %s\n' "${dockerfile}"
      for arch in $(arch_list_to_words "${arches_csv}"); do
        tag="$(cross_stage_tag "${stage}" "${arch}")"
        printf '  %-6s → %s\n' "${arch}" "${tag}"
      done
    elif [ "${stage}" = "runtime" ]; then
      printf '\n[%s]  ← %s\n' "${stage}" "${parent:-N/A}"
      printf '  Delegates to: build-runtime-manifest.sh\n'
      printf '  Produces:     :latest-cross multi-arch manifest\n'
    else
      tag="$(cross_stage_tag "${stage}")"
      printf '\n[%s]  ← %s\n' "${stage}" "${parent:-ubuntu:26.04}"
      printf '  Dockerfile: %s\n' "${dockerfile}"
      printf '  Tag:        %s\n' "${tag}"
      printf '  Platform:   linux/amd64  (shared, not per-arch)\n'
    fi
  done
  printf '\n'
}
