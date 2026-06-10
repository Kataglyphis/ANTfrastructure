#!/usr/bin/env bash
# cross-stage-build.sh — shared cross-lane stage build functions.
#
# Source this directly or through artifact-common.sh.
# Depends on: build-helpers.sh, stage-defs.sh, digest-pinning.sh, logging.sh.
[ -n "${_CROSS_STAGE_BUILD_SH_LOADED:-}" ] && return 0
_CROSS_STAGE_BUILD_SH_LOADED=1
#
# Provides:
#   cross_stage_log_redirect()       — compute log file path for a stage build
#   cross_stage_build_and_push()     — build a cross stage on linux/amd64 and push
#   cross_stage_resolve_parent_pin() — resolve parent digest for stage transition
#   resolve_pin()                    — low-level pin resolution (captured → registry)
#   cross_stage_run()                — full orchestration: resolve parent, build, capture pin
#
# These functions are consumed by:
#   - build-cross-chain.sh (full orchestrator)
#   - build-cross-stage.sh (single-stage rebuilds)
#   - build-cross-compiler.sh (standalone compiler entry point)

# ==============================================================================
# cross_stage_log_redirect
#
# Computes a log file path for the given label when LOG_DIR is set.
# Usage: log_file="$(cross_stage_log_redirect "sdk-arm64")"
# ==============================================================================
cross_stage_log_redirect() {
  local label="$1"
  if [ -n "${LOG_DIR:-}" ]; then
    mkdir -p "${LOG_DIR}"
    printf '%s/%s.log' "${LOG_DIR}" "${label}"
  fi
}

# ==============================================================================
# cross_stage_build_and_push
#
# Build a cross-lane stage image on linux/amd64, push it to the registry, and
# optionally tee output to a log file.
#
# Automatically disables --pull when BASE_IMAGE is already digest-pinned
# (repo@sha256:...), since the digest uniquely identifies the image and can
# never resolve to a stale version.
#
# Uses registry build cache via --cache-from / --cache-to for faster rebuilds.
# Respects DRY_RUN (when set to 1, prints the command without executing).
#
# Usage: cross_stage_build_and_push <label> <tag> <dockerfile> [extra build args...]
# ==============================================================================
cross_stage_build_and_push() {
  local label="$1" tag="$2" dockerfile="$3"
  shift 3
  local -a extra=("$@")
  local -a common_args=()
  append_common_build_args common_args

  local log_file
  log_file="$(cross_stage_log_redirect "${label}")"

  local pull_flag="--pull=true"
  if _has_digest_pinned_base "${extra[@]}"; then
    pull_flag="--pull=false"
  fi

  local -a build_cmd=(
    "${NERDCTL_BIN:-nerdctl}" build
    "${pull_flag}"
    --platform linux/amd64
    -t "${tag}"
    --output "type=image,name=${tag},push=true"
    --cache-from "type=registry,ref=${tag}-buildcache"
    --cache-to "type=registry,ref=${tag}-buildcache,mode=max"
    -f "${dockerfile}"
  )
  append_buildkit_host_arg build_cmd
  build_cmd+=("${extra[@]}" "${common_args[@]}" .)

  if [ "${DRY_RUN:-0}" -eq 1 ]; then
    printf '[DRY RUN] '
    printf '%q ' "${build_cmd[@]}"
    printf '\n'
    return 0
  fi

  if [ -n "${log_file}" ]; then
    run "${build_cmd[@]}" > >(tee -a "${log_file}") 2>&1
  else
    run "${build_cmd[@]}"
  fi
}

# ==============================================================================
# cross_stage_resolve_parent_pin
#
# Resolve the digest-pinned parent reference for a stage using the stage graph.
# Checks captured pins from this orchestration run first; falls back to the
# parent tag's current registry digest if the parent wasn't built in this run
# (e.g. when using --from-stage to resume mid-chain).
#
# Returns an empty string for the base stage (no parent).
#
# The captured pins are accessed via cross_stage_pin_varname() from stage-defs.sh.
# The caller's scope must contain the pin variables (BASE_PIN, COMPILER_PIN,
# SDK_PIN[], MEDIA_PIN[], ANDROID_PIN[]) as declared by the orchestrator.
#
# Usage: parent_pin="$(cross_stage_resolve_parent_pin "media" "arm64")"
# ==============================================================================
cross_stage_resolve_parent_pin() {
  local stage="$1" arch="${2:-}"
  local parent parent_tag parent_pin_varname captured

  parent="$(cross_stage_parent "${stage}")"
  [ -z "${parent}" ] && return 0  # base has no parent

  parent_tag="$(cross_stage_tag "${parent}" "${arch}")"
  [ -z "${parent_tag}" ] && { warn "No tag for parent stage '${parent}' of '${stage}'"; return 1; }

  parent_pin_varname="$(cross_stage_pin_varname "${parent}")"
  [ -z "${parent_pin_varname}" ] && { warn "No pin varname for parent stage '${parent}'"; return 1; }

  if cross_stage_is_per_arch "${parent}"; then
    local -n pin_map="${parent_pin_varname}"
    captured="${pin_map[$arch]:-}"
  else
    captured="${!parent_pin_varname:-}"
  fi

  if [ "${DRY_RUN:-0}" -eq 1 ]; then
    printf '%s' "${captured:-${parent_tag}@sha256:dry-run-placeholder}"
    return 0
  fi

  resolve_pin "${captured}" "${parent_tag}"
}

# ==============================================================================
# resolve_pin
#
# Resolve a digest pin: prefer a captured value from this orchestration run,
# otherwise fall back to the registry digest of the given tag.
#
# Usage: pinned_ref="$(resolve_pin "${captured}" "${tag}")"
# ==============================================================================
resolve_pin() {
  local captured="$1" tag="$2"
  if [ -n "${captured}" ]; then
    printf '%s' "${captured}"
    return 0
  fi
  local result
  result="$(retry 3 10 "registry digest for ${tag}" registry_pin_ref "${NERDCTL_BIN:-nerdctl}" "${tag}")" || {
    warn "Failed to resolve registry digest for ${tag}. Is the image pushed?"
    return 1
  }
  if [ -z "${result}" ]; then
    warn "Registry pin ref returned empty for ${tag}. Is the image pushed?"
    return 1
  fi
  printf '%s' "${result}"
}

# ==============================================================================
# cross_stage_run
#
# Full cross-stage orchestration: resolve the parent digest, assemble build args,
# run the build+publish, and capture the output digest pin.
#
# On success, the captured pin is stored in the appropriate pin variable
# (BASE_PIN, COMPILER_PIN, SDK_PIN[arch], etc.) as determined by the stage graph.
#
# The caller's scope must contain the pin variables and the ANDROID_BUILT_THIS_RUN
# associative array (for tracking android stage rebuilds).
#
# Usage: cross_stage_run "media" "arm64"
# ==============================================================================
cross_stage_run() {
  local stage="$1" arch="${2:-}"
  local label tag dockerfile parent_pin pin_varname
  local -a build_args=()

  label="${stage}"
  cross_stage_is_per_arch "${stage}" && label="${stage}-${arch}"

  dockerfile="$(cross_stage_dockerfile "${stage}")" || {
    err "Stage '${stage}' is not known. Valid stages: ${CROSS_STAGE_ORDER[*]}"
  }
  [ -z "${dockerfile}" ] && {
    err "Stage '${stage}' has no Dockerfile (it delegates to another script — use a different entry point)"
  }
  tag="$(cross_stage_tag "${stage}" "${arch}")"
  [ -z "${tag}" ] && { err "No tag for stage: ${stage} ${arch:+arch=${arch}}"; }

  # Resolve the parent digest pin for this stage
  parent_pin="$(cross_stage_resolve_parent_pin "${stage}" "${arch}")" || {
    err "Failed to resolve parent pin for stage '${stage}' (parent: $(cross_stage_parent "${stage}")). Ensure the parent image is pushed to the registry."
  }
  if [ -n "${parent_pin}" ]; then
    build_args+=(--build-arg "BASE_IMAGE=${parent_pin}")
  fi

  # Append stage-specific build args from the stage graph
  cross_stage_build_args build_args "${stage}" "${arch}"

  log "[stage ${label}] building ${tag}${parent_pin:+ FROM ${parent_pin}}"
  cross_stage_build_and_push "${label}" "${tag}" "${dockerfile}" "${build_args[@]}"

  # Capture the digest pin for downstream stages
  if [ "${DRY_RUN:-0}" -eq 1 ]; then
    log "[stage ${label}] [DRY RUN] would pin ${tag}"
    return 0
  fi
  pin_varname="$(cross_stage_pin_varname "${stage}")"
  [ -z "${pin_varname}" ] && { err "No pin varname for stage: ${stage}"; }

  local pinned_digest
  pinned_digest="$(retry 5 10 "registry digest for ${tag}" registry_pin_ref "${NERDCTL_BIN:-nerdctl}" "${tag}")"
  [ -z "${pinned_digest}" ] && { err "Failed to capture digest pin for ${tag}"; }

  if cross_stage_is_per_arch "${stage}"; then
    local -n pin_map="${pin_varname}"
    pin_map["${arch}"]="${pinned_digest}"
    log "[stage ${label}] pinned ${pinned_digest}"
    # Track android rebuilds so the runtime stage knows whether to re-pull
    if [ "${stage}" = "android" ] && declare -p ANDROID_BUILT_THIS_RUN &>/dev/null; then
      ANDROID_BUILT_THIS_RUN["${arch}"]=1
    fi
  else
    printf -v "${pin_varname}" '%s' "${pinned_digest}"
    log "[stage ${label}] pinned ${!pin_varname}"
  fi
}
