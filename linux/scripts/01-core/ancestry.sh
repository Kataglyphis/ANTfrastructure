#!/usr/bin/env bash
# ancestry.sh — machine-checked stage ancestry for the cross lane.
#
# Source this directly or through artifact-common.sh.
# Depends on: stage-defs.sh, digest-pinning.sh, tag-naming.sh, logging.sh.
[ -n "${_ANCESTRY_SH_LOADED:-}" ] && return 0
_ANCESTRY_SH_LOADED=1
_ANCESTRY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#
# ── WHY THIS EXISTS ───────────────────────────────────────────────────────────
#
# Digest pinning (digest-pinning.sh) guarantees that WITHIN one orchestrator run
# each stage consumes the image its parent just produced. It says nothing about
# runs that start mid-chain. The documented failure (docs/linux-cross-builds.md
# § "Trap: stale-base propagation across orchestrator invocations") is:
#
#   1. Full chain built:            compiler → sdk → media → android
#   2. compiler rebuilt and pushed  (e.g. new /opt/gcc-16.2.0-native-arm64)
#   3. `--from-stage media` runs    → resolves the sdk pin from tag :cross-sdk-*
#                                     which was built from the OLD compiler
#   4. media inherits the stale sdk; the new compiler content never lands.
#
# Nothing in the pipeline could detect step 3 — the sdk tag resolves fine, it is
# simply the wrong ancestor. Until now the only defense was a rule in a document
# ("after a compiler push, start from --from-stage sdk"), i.e. human discipline
# guarding a machine invariant. This module turns it into a check.
#
# ── HOW ───────────────────────────────────────────────────────────────────────
#
# WRITE: every pushed cross stage records the digest-pinned reference it was
# actually built FROM as an OCI manifest annotation
# (org.kataglyphis.parent-digest). This is free: it rides along in the manifest
# the push already writes.
#
# READ: `nerdctl manifest inspect --verbose` returns the verbatim registry
# manifest in its base64 `Raw` field, so the annotation is readable without
# pulling the image or fetching config blobs — see manifest-annotation.py.
#
# ASSERT: before a partial run builds stage S, walk the ancestor chain of
# parent(S) upward. For each link child→parent, the digest the child RECORDS
# must equal the digest the parent tag CURRENTLY resolves to. A mismatch means
# the parent was rebuilt after the child — exactly the stale-base case — and is
# a hard failure with the specific --from-stage that repairs it.
#
# ── FAILURE SEMANTICS ─────────────────────────────────────────────────────────
#
# Absent annotation  → WARN. Images built before this module have no annotation;
#                      provenance is unknown, not known-bad. Warning keeps the
#                      rollout non-breaking: pre-existing images stay usable and
#                      every image built from now on is checked.
# Present + mismatch → FAIL. This is positive evidence of a stale ancestor.
# Unresolvable tag   → WARN. A missing parent tag is the build's problem to
#                      report, not an ancestry violation.
#
# Provides:
#   ancestry_output_annotations()  — output-opt fragment recording the parent pin
#   ancestry_recorded_parent()     — read the recorded parent ref off an image
#   ancestry_assert_chain()        — assert the ancestor chain feeding a stage

ANCESTRY_PARENT_DIGEST_KEY="${ANCESTRY_PARENT_DIGEST_KEY:-org.kataglyphis.parent-digest}"
ANCESTRY_PARENT_STAGE_KEY="${ANCESTRY_PARENT_STAGE_KEY:-org.kataglyphis.parent-stage}"

# ==============================================================================
# ancestry_output_annotations
#
# Emit the `,annotation.<key>=<value>` fragment appended to the image exporter's
# --output string, recording which parent reference this build consumed.
# Prints nothing when there is no parent (the base stage) — so the caller can
# always append the result unconditionally.
#
# Both keys are plain OCI manifest annotations; buildkit's image exporter accepts
# them via `annotation.<key>=<value>` and they survive the push (the registry
# manifests here are OCI, not docker v2, which has no annotations field).
#
# Usage: out_opts="type=image,name=${tag},push=true$(ancestry_output_annotations "${pin}" "${parent_stage}")"
# ==============================================================================
ancestry_output_annotations() {
  local parent_pin="${1:-}" parent_stage="${2:-}"
  [ -n "${parent_pin}" ] || return 0
  # A comma would be read as an output-opt separator and corrupt the exporter
  # spec. Image refs never contain one; refuse rather than emit a broken --output.
  case "${parent_pin}" in
    *,*) warn "[ancestry] parent pin contains a comma, not recording: ${parent_pin}"; return 0 ;;
  esac
  printf ',annotation.%s=%s' "${ANCESTRY_PARENT_DIGEST_KEY}" "${parent_pin}"
  [ -n "${parent_stage}" ] && printf ',annotation.%s=%s' "${ANCESTRY_PARENT_STAGE_KEY}" "${parent_stage}"
  return 0
}

# ==============================================================================
# ancestry_recorded_parent
#
# Print the parent reference recorded on <image_ref>.
# Exit 0 with the value, 2 when the image carries no annotation (unknown
# provenance), 1 when the manifest could not be read at all.
#
# Usage: recorded="$(ancestry_recorded_parent "${tag}")"
# ==============================================================================
ancestry_recorded_parent() {
  local image_ref="$1"
  local helper="${_ANCESTRY_DIR}/manifest-annotation.py"

  if ! command -v python3 >/dev/null 2>&1 || [ ! -f "${helper}" ]; then
    return 1
  fi

  local manifest_json
  manifest_json="$("${NERDCTL_BIN:-nerdctl}" manifest inspect --verbose "${image_ref}" 2>/dev/null)" || return 1
  [ -n "${manifest_json}" ] || return 1

  printf '%s' "${manifest_json}" | python3 "${helper}" "${ANCESTRY_PARENT_DIGEST_KEY}" 2>/dev/null
}

# Digest half of a `repo@sha256:...` reference.
#
# Comparison is on the DIGEST, not the whole ref: --image-repo can legitimately
# move the chain to another registry path, which changes every repo prefix while
# the content ancestry is untouched. The digest is the actual identity claim.
_ancestry_digest_of() {
  local ref="${1:-}"
  printf '%s' "${ref##*@}"
}

# Verify one child→parent link. Returns 1 only on a genuine mismatch.
_ancestry_check_link() {
  local child_ref="$1" parent_ref="$2" label="$3"
  local recorded current rc=0

  recorded="$(ancestry_recorded_parent "${child_ref}")" || rc=$?
  if [ "${rc}" -ne 0 ] || [ -z "${recorded}" ]; then
    warn "[ancestry] ${label}: ${child_ref} records no parent digest — provenance unverifiable (image predates ancestry annotations; rebuild it to enable this check)"
    return 0
  fi

  current="$(registry_pin_ref "${NERDCTL_BIN:-nerdctl}" "${parent_ref}" 2>/dev/null || true)"
  if [ -z "${current}" ]; then
    warn "[ancestry] ${label}: parent tag ${parent_ref} is not resolvable in the registry — skipping ancestry check"
    return 0
  fi

  if [ "$(_ancestry_digest_of "${recorded}")" = "$(_ancestry_digest_of "${current}")" ]; then
    log "[ancestry] ${label}: OK ($(_ancestry_digest_of "${current}"))"
    return 0
  fi

  warn "[ancestry] ${label}: STALE ANCESTOR"
  warn "[ancestry]   ${child_ref}"
  warn "[ancestry]     was built FROM : ${recorded}"
  warn "[ancestry]     but ${parent_ref} now resolves to"
  warn "[ancestry]                    : ${current}"
  return 1
}

# Walk one architecture's ancestor chain upward from <child> to base.
_ancestry_assert_branch() {
  local child="$1" arch="$2"
  local parent child_ref parent_ref label rc=0
  local depth=0

  while [ -n "${child}" ]; do
    parent="$(cross_stage_parent "${child}")"
    [ -z "${parent}" ] && break   # reached base: no parent to compare against

    # Depth guard: cross_stage_validate_graph already rejects cycles, but this
    # loop must never become the thing that hangs a build.
    depth=$((depth + 1))
    [ "${depth}" -gt "${#CROSS_STAGE_ORDER[@]}" ] && break

    child_ref="$(cross_stage_tag "${child}" "${arch}" 2>/dev/null || true)"
    parent_ref="$(cross_stage_tag "${parent}" "${arch}" 2>/dev/null || true)"
    if [ -n "${child_ref}" ] && [ -n "${parent_ref}" ]; then
      label="${parent}→${child}"
      cross_stage_is_per_arch "${child}" && label="${label} (${arch})"
      _ancestry_check_link "${child_ref}" "${parent_ref}" "${label}" || rc=1
    fi

    child="${parent}"
  done

  return "${rc}"
}

# ==============================================================================
# ancestry_assert_chain
#
# Assert that every already-built ancestor feeding <from_stage> is fresh.
#
# No-op when <from_stage> is base (nothing was built earlier, so nothing can be
# stale) — which is why a full from-base run pays nothing for this check.
#
# Returns 1 if any link is a confirmed stale ancestor.
#
# Usage: ancestry_assert_chain "media" "amd64,arm64"
# ==============================================================================
ancestry_assert_chain() {
  local from_stage="$1" arches_csv="$2"
  local start_parent arch rc=0

  start_parent="$(cross_stage_parent "${from_stage}")"
  [ -z "${start_parent}" ] && return 0   # from base: no prior stages to verify

  log "[ancestry] verifying the ancestor chain feeding stage '${from_stage}' (arches: ${arches_csv})"

  for arch in $(arch_list_to_words "${arches_csv}"); do
    _ancestry_assert_branch "${start_parent}" "${arch}" || rc=1
  done

  if [ "${rc}" -ne 0 ]; then
    warn "[ancestry] ---"
    warn "[ancestry] A parent image was rebuilt AFTER the child that consumes it."
    warn "[ancestry] Starting at '${from_stage}' would silently build on the stale child."
    warn "[ancestry] Fix: rerun --from-stage at or before the OLDEST stage reported"
    warn "[ancestry]      above, so the rebuilt content propagates down the chain."
    warn "[ancestry] Override (you accept the stale ancestor): CROSS_VERIFY_ANCESTRY=0"
  else
    log "[ancestry] ancestor chain verified"
  fi
  return "${rc}"
}
