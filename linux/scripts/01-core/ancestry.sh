#!/usr/bin/env bash
# ancestry.sh — machine-checked stage ancestry for the cross lane.
#
# Source this directly or through artifact-common.sh.
# Depends on: stage-defs.sh, digest-pinning.sh, tag-naming.sh, logging.sh.
[ -n "${_ANCESTRY_SH_LOADED:-}" ] && return 0
_ANCESTRY_SH_LOADED=1
_ANCESTRY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#
# Turns "after a compiler push, start from --from-stage sdk" from human
# discipline into a machine check: each pushed stage records the digest it was
# built FROM as an OCI annotation, and a partial run asserts the recorded digest
# still matches what the parent tag resolves to. Mechanism, failure semantics and
# the trap it prevents: docs/linux-cross-builds.md § Trap: stale-base propagation
# across orchestrator invocations.

ANCESTRY_PARENT_DIGEST_KEY="${ANCESTRY_PARENT_DIGEST_KEY:-org.kataglyphis.parent-digest}"
ANCESTRY_PARENT_STAGE_KEY="${ANCESTRY_PARENT_STAGE_KEY:-org.kataglyphis.parent-stage}"
# Which orchestrator generation produced an image. The runtime lane stamps this
# on the per-arch wrapper pushes so a later manifest run can prove the three
# tags it is about to index came from ONE run (XC3), not a mix of generations.
ANCESTRY_RUN_ID_KEY="${ANCESTRY_RUN_ID_KEY:-org.kataglyphis.run-id}"

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
# ancestry_run_id_annotation
#
# Emit the `,annotation.<run-id-key>=<value>` fragment recording which
# orchestrator generation produced this build. Prints nothing for an empty run
# id, so callers can append the result unconditionally (mirrors
# ancestry_output_annotations). XC3 reads this back off the per-arch wrapper
# tags to refuse assembling a mixed-generation manifest.
#
# Usage: out="type=image,name=${tag}$(ancestry_run_id_annotation "${CROSS_RUN_ID}")"
# ==============================================================================
ancestry_run_id_annotation() {
  local run_id="${1:-}"
  [ -n "${run_id}" ] || return 0
  case "${run_id}" in
    *,*) warn "[ancestry] run id contains a comma, not recording: ${run_id}"; return 0 ;;
  esac
  printf ',annotation.%s=%s' "${ANCESTRY_RUN_ID_KEY}" "${run_id}"
  return 0
}

# ==============================================================================
# ancestry_label_args
#
# Append `--label <key>=<value>` provenance args to the nameref array.
#
# XC3-INERT fix (2026-08-23): the runtime lane builds with plain `-t` (RTCACHE3
# forced that — the `--output type=image` exporter never lands a local
# containerd tag on rootless, which shipped five stale images), and `-t` cannot
# carry exporter annotations. Labels can: they live in the image CONFIG blob,
# so they survive `-t`, survive the later `nerdctl push`, and are readable back
# with `nerdctl image inspect`. Same key constants as the annotation path, so
# readers and tests keep ONE vocabulary.
#
# Unlike the annotation fragment there is no comma hazard here (no output-opt
# parsing), but an embedded newline would still corrupt the arg list, so refuse
# those. Emits nothing for empty values — callers may append unconditionally.
#
# Usage: local -a out=(); ancestry_label_args out "${pin}" android "${CROSS_RUN_ID}"
# ==============================================================================
ancestry_label_args() {
  local -n _al_out="$1"
  local parent_pin="${2:-}" parent_stage="${3:-}" run_id="${4:-}"

  _ancestry_label_safe() {
    case "${1:-}" in
      "") return 1 ;;
      *$'\n'*) warn "[ancestry] provenance value contains a newline, not recording"; return 1 ;;
    esac
    return 0
  }

  if _ancestry_label_safe "${run_id}"; then
    _al_out+=(--label "${ANCESTRY_RUN_ID_KEY}=${run_id}")
  fi
  if _ancestry_label_safe "${parent_pin}"; then
    _al_out+=(--label "${ANCESTRY_PARENT_DIGEST_KEY}=${parent_pin}")
    if _ancestry_label_safe "${parent_stage}"; then
      _al_out+=(--label "${ANCESTRY_PARENT_STAGE_KEY}=${parent_stage}")
    fi
  fi
  unset -f _ancestry_label_safe
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
ancestry_recorded_annotation() {
  local image_ref="$1" key="${2:-${ANCESTRY_PARENT_DIGEST_KEY}}"
  local helper="${_ANCESTRY_DIR}/manifest-annotation.py"

  if ! command -v python3 >/dev/null 2>&1 || [ ! -f "${helper}" ]; then
    return 1
  fi

  local manifest_json
  manifest_json="$("${NERDCTL_BIN:-nerdctl}" manifest inspect --verbose "${image_ref}" 2>/dev/null)" || return 1
  [ -n "${manifest_json}" ] || return 1

  printf '%s' "${manifest_json}" | python3 "${helper}" "${key}" 2>/dev/null
}

# Read a provenance value out of the image CONFIG labels (the runtime lane's
# `-t` path stamps these; see ancestry_label_args). Exit 0 + value, 2 when the
# label is absent, 1 when the image cannot be inspected at all.
#
# This reads the LOCAL image, whereas the annotation reader queries the
# registry — and reading provenance off a STALE local tag is precisely the
# class of bug that caused the RTCACHE3 stale-ship saga. So when the ref also
# resolves in the registry, require the local bytes to BE the shipped bytes
# before trusting their labels; on a mismatch report unreadable (1) and let the
# caller fall through rather than answer from the wrong image.
ancestry_recorded_label() {
  local image_ref="$1" key="${2:-${ANCESTRY_PARENT_DIGEST_KEY}}"
  local nerdctl="${NERDCTL_BIN:-nerdctl}"
  local value

  value="$("${nerdctl}" image inspect --format "{{index .Config.Labels \"${key}\"}}" \
            "${image_ref}" 2>/dev/null)" || return 1
  case "${value}" in
    ""|"<no value>") return 2 ;;
  esac

  if declare -F registry_pin_ref >/dev/null 2>&1; then
    local remote local_digests
    remote="$(registry_pin_ref "${nerdctl}" "${image_ref}" 2>/dev/null || true)"
    if [ -n "${remote}" ]; then
      local_digests="$("${nerdctl}" image inspect --format '{{json .RepoDigests}}' \
                        "${image_ref}" 2>/dev/null || true)"
      case "${local_digests}" in
        *"${remote##*@}"*) ;;
        *) warn "[ancestry] ${image_ref}: local tag is not the registry copy (${remote##*@}) — ignoring its provenance labels"
           return 1 ;;
      esac
    fi
  fi

  printf '%s' "${value}"
}

# Read a provenance label off the REGISTRY copy, without pulling the image
# (manifest + config blob only, a few KB). This is what makes the XC3 gate work
# in the case it exists for — a --repair / --manifest-only run, possibly on a
# host that never built the wrappers, where the local store has no tag to
# inspect. Same exit contract: 0 value, 2 absent, 1 unreadable.
ancestry_recorded_registry_label() {
  local image_ref="$1" key="${2:-${ANCESTRY_PARENT_DIGEST_KEY}}"
  local helper="${_ANCESTRY_DIR}/registry-config-label.py"

  command -v python3 >/dev/null 2>&1 || return 1
  [ -f "${helper}" ] || return 1
  python3 "${helper}" "${image_ref}" "${key}" 2>/dev/null
}

# Read a provenance value from wherever this image records it: config LABELS
# first (runtime lane, `-t` path), then manifest ANNOTATIONS (cross lane, which
# pushes through the exporter and so still carries them). Preserves the
# exit-code contract callers branch on: 0 = value, 2 = absent, 1 = unreadable.
ancestry_recorded_provenance() {
  local image_ref="$1" key="$2"
  local value label_rc=0 ann_rc=0

  value="$(ancestry_recorded_label "${image_ref}" "${key}")" || label_rc=$?
  if [ "${label_rc}" -eq 0 ] && [ -n "${value}" ]; then
    printf '%s' "${value}"
    return 0
  fi

  # The local store could not answer (no such tag, or its bytes are not the
  # shipped bytes). Ask the registry for the same label — the push carried it
  # in the config blob.
  local reg_rc=0
  value="$(ancestry_recorded_registry_label "${image_ref}" "${key}")" || reg_rc=$?
  if [ "${reg_rc}" -eq 0 ] && [ -n "${value}" ]; then
    printf '%s' "${value}"
    return 0
  fi

  value="$(ancestry_recorded_annotation "${image_ref}" "${key}")" || ann_rc=$?
  if [ "${ann_rc}" -eq 0 ] && [ -n "${value}" ]; then
    printf '%s' "${value}"
    return 0
  fi

  # Keep 2 ("absent") distinct from 1 ("could not read"): a caller must never
  # mistake an auth or network problem for "this image has no provenance".
  # Absent wins only if some reader actually got to look at the image.
  if [ "${label_rc}" -eq 2 ] || [ "${reg_rc}" -eq 2 ]; then
    return 2
  fi
  return "${ann_rc:-1}"
}

# Read the recorded parent digest (thin wrapper kept for existing callers).
ancestry_recorded_parent() {
  ancestry_recorded_provenance "$1" "${ANCESTRY_PARENT_DIGEST_KEY}"
}

# Read the recorded orchestrator run id (empty/exit-2 when unstamped).
ancestry_recorded_run_id() {
  ancestry_recorded_provenance "$1" "${ANCESTRY_RUN_ID_KEY}"
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

# ==============================================================================
# runtime_ancestry_assert_wrappers  (XC2 — runtime-lane ancestry coverage)
#
# The cross-lane walker (ancestry_assert_chain) stops at android: the runtime
# lane's base/package/wrapper build on a different platform and, in the normal
# flow, only the wrapper is pushed (base/package are local intermediates). The
# one immutable, registry-resident ancestor a pushed wrapper has is the android
# artifact it was packaged from, stamped as its parent-digest annotation (see
# runtime-build-fns.sh). This walks the runtime-lane graph table
# (RUNTIME_STAGE_PARENT_MAP → android) and verifies each per-arch wrapper still
# descends from the CURRENT android tag — the "wrapper predating its android"
# case a --repair/standalone manifest run could not previously detect.
#
# Reuses _ancestry_check_link, so the verdict semantics match the cross lane:
# absent annotation → WARN (pre-XC2 image, non-breaking), unresolvable tag →
# WARN, present + digest mismatch → FAIL (rc 1).
#
# Usage: runtime_ancestry_assert_wrappers "amd64,arm64,riscv64"
# ==============================================================================
runtime_ancestry_assert_wrappers() {
  local arches_csv="$1" arch rc=0 wrapper_ref android_ref
  declare -F runtime_stage_tag >/dev/null 2>&1 || return 0
  local parent_stage
  for arch in $(arch_list_to_words "${arches_csv}"); do
    wrapper_ref="$(runtime_stage_tag wrapper "${arch}" 2>/dev/null || true)"
    [ -n "${wrapper_ref}" ] || continue
    # XC2-STAGE (2026-08-23): compare against the stage the WRITER actually
    # stamped, never runtime_stage_parent's answer. append_runtime_image_output
    # records the ANDROID pin (the artifact source the package COPYs from), but
    # `runtime_stage_parent wrapper` returns "package" — so this used to resolve
    # a PACKAGE tag and compare it against a recorded ANDROID digest. While
    # provenance was inert that mismatch was invisible (the check bailed out at
    # "records no parent digest"); the moment labels land it would have failed
    # every single run with a false STALE ANCESTOR. Prefer the recorded
    # parent-stage, fall back to the writer's constant.
    parent_stage="$(ancestry_recorded_provenance "${wrapper_ref}" "${ANCESTRY_PARENT_STAGE_KEY}" 2>/dev/null || true)"
    [ -n "${parent_stage}" ] || parent_stage=android
    # Resolve the android ref the way the WRITER did, i.e. through the prefix
    # that is threaded across the process boundary (--artifact-image-prefix →
    # ARTIFACT_IMAGE_PREFIX). runtime_stage_tag android → cross_android_tag →
    # "${IMAGE_REPO:-${IMAGE_REGISTRY_PREFIX}}", and IMAGE_REPO is set ONLY by
    # orchestrator_preamble and never exported — build-runtime-manifest.sh runs
    # as a separate child that calls runtime_flow_preamble, so under
    # --image-repo <fork> that helper silently returns the DEFAULT repo. The
    # recorded pin would then be compared against a foreign repo's android tag
    # and every --repair run would hard-refuse a perfectly good manifest
    # (android_stale is a gate, not a warning, when BUILD_IMAGES=0).
    android_ref=""
    if [ "${parent_stage}" = "android" ] && declare -F runtime_artifact_image_ref >/dev/null 2>&1; then
      android_ref="$(runtime_artifact_image_ref "${arch}" 2>/dev/null || true)"
    fi
    if [ -z "${android_ref}" ]; then
      android_ref="$(runtime_stage_tag "${parent_stage}" "${arch}" 2>/dev/null || true)"
    fi
    [ -n "${android_ref}" ] || continue
    _ancestry_check_link "${wrapper_ref}" "${android_ref}" "${parent_stage}→wrapper (${arch})" || rc=1
  done
  return "${rc}"
}

# ==============================================================================
# manifest generation coherence (XC3)
#
# The per-arch wrapper tags are mutable and go LIVE inside the build loop, before
# the manifest is smoke-gated. A later --repair run indexes whatever those tags
# currently hold; a 2-of-3 rebuild leaves one arch on an older generation, so
# indexing them ships a mixed-generation :latest-cross. The run-id annotation
# (ancestry_run_id_annotation) is the coherence key: three tags from one run
# share it.
# ==============================================================================

# Print each non-empty argument once, de-duplicated. Empty args (a tag with no
# run-id annotation) are dropped — "unknown provenance", not a distinct
# generation.
_ancestry_distinct_nonempty() {
  local a
  for a in "$@"; do [ -n "${a}" ] && printf '%s\n' "${a}"; done | sort -u
}

# Return 0 when every PRESENT (non-empty) run id is identical — i.e. the tags are
# one coherent generation (or provenance is simply unknown). Return 1 when two or
# more DIFFERENT run ids are present: the tags mix generations and indexing them
# would ship a Frankenstein manifest.
#
# Usage: ancestry_run_ids_coherent "${run_id_amd64}" "${run_id_arm64}" ...
ancestry_run_ids_coherent() {
  local -a distinct
  mapfile -t distinct < <(_ancestry_distinct_nonempty "$@")
  [ "${#distinct[@]}" -le 1 ]
}
