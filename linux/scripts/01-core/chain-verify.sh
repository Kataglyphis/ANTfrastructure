#!/usr/bin/env bash
# Cross-chain staleness checks; needs stage-defs.sh, digest-pinning.sh, logging.sh, tag-naming.sh.
[ -n "${_CHAIN_VERIFY_SH_LOADED:-}" ] && return 0
_CHAIN_VERIFY_SH_LOADED=1
_CHAIN_VERIFY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_resolve_pin_or_empty() {
  local nerdctl_bin="$1" tag="$2" d
  d="$(registry_pin_ref "${nerdctl_bin}" "${tag}" 2>/dev/null || true)"
  [ -n "${d}" ] || return 1
  printf '%s' "${d}"
}

# _verify_link <label> <parent_tag> <child_tag>: non-fatal; stale links count into _CHAIN_VERIFY_STALE_COUNT.
_verify_link() {
  local label="$1" parent_tag="$2" child_tag="$3" parent_digest child_base_digest

  parent_digest="$(retry 5 5 "registry digest for ${parent_tag}" \
    _resolve_pin_or_empty "${NERDCTL_BIN:-nerdctl}" "${parent_tag}" 2>/dev/null || true)"
  if [ -z "${parent_digest}" ]; then
    warn "[verify] ${label}: parent tag ${parent_tag} not resolvable in registry"
    return 0
  fi

  # A recorded parent gives a real verdict; older images only get a digest dump below.
  if declare -F ancestry_recorded_parent >/dev/null 2>&1; then
    local recorded
    recorded="$(ancestry_recorded_parent "${child_tag}" 2>/dev/null || true)"
    if [ -n "${recorded}" ]; then
      if [ "${recorded##*@}" = "${parent_digest##*@}" ]; then
        log "[verify] ${label}: FRESH (child was built from the parent's current digest)"
      else
        warn "[verify] ${label}: STALE — child built FROM ${recorded##*@}, parent now ${parent_digest##*@}"
        warn "[verify] ${label}:   rebuild from stage '${label%%->*}' (or later ancestors stay stale)"
        _CHAIN_VERIFY_STALE_COUNT=$(( ${_CHAIN_VERIFY_STALE_COUNT:-0} + 1 ))
      fi
      return 0
    fi
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    warn "[verify] ${label}: python3 not available, skipping base layer check"
    return 0
  fi

  child_base_digest="$("${NERDCTL_BIN:-nerdctl}" manifest inspect "${child_tag}" 2>/dev/null \
    | python3 "${_CHAIN_VERIFY_DIR:-${_ARTIFACT_COMMON_DIR}}/manifest-base-layer.py" 2>/dev/null || true)"

  if [ -n "${child_base_digest}" ]; then
    log "[verify] ${label}: no ancestry annotation (predates the mechanism) — manual check:"
    log "[verify] ${label}: parent ${parent_digest}"
    log "[verify] ${label}: child  ${child_tag}"
    log "[verify] ${label}: child base layer ${child_base_digest}"
  else
    log "[verify] ${label}: parent digest ${parent_digest} (child tag unresolvable)"
  fi
}

# verify_cross_chain_staleness <arches_csv>: 1 when any link is stale.
verify_cross_chain_staleness() {
  local arches_csv="$1"
  local stage parent parent_tag child_tag arch label
  _CHAIN_VERIFY_STALE_COUNT=0

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

  if [ "${_CHAIN_VERIFY_STALE_COUNT:-0}" -gt 0 ]; then
    warn "[verify] chain check complete: ${_CHAIN_VERIFY_STALE_COUNT} STALE link(s)"
    return 1
  fi
  log "[verify] chain check complete: all links fresh (or pre-annotation)"
}

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
      # Say before the run that android's payload will be empty on this host.
      if [ "${stage}" = "android" ] && \
         command -v android_build_host_supported >/dev/null 2>&1 && \
         ! android_build_host_supported; then
        printf '  Payload:    SKIPPED (Android NDK is prebuilt/linux-x86_64 only; build host is %s)\n' \
          "$(build_arch_oci)"
      fi
      for arch in $(arch_list_to_words "${arches_csv}"); do
        tag="$(cross_stage_tag "${stage}" "${arch}")"
        printf '  %-6s → %s\n' "${arch}" "${tag}"
      done
    elif [ "${stage}" = "runtime" ]; then
      printf '\n[%s]  ← %s\n' "${stage}" "${parent:-N/A}"
      printf '  Delegates to: build-runtime-manifest.sh\n'
      printf '  Produces:     %s multi-arch manifest\n' "${FINAL_IMAGE:-$(cross_final_image_tag)}"
    else
      tag="$(cross_stage_tag "${stage}")"
      printf '\n[%s]  ← %s\n' "${stage}" "${parent:-ubuntu:26.04}"
      printf '  Dockerfile: %s\n' "${dockerfile}"
      printf '  Tag:        %s\n' "${tag}"
      printf '  Platform:   %s  (shared, not per-arch)\n' "$(cross_build_platform)"
    fi
  done
  printf '\n'
}
