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
#   _cross_stage_build_impl()        — internal: build cross stage (push or local)
#   cross_stage_build_and_push()     — build a cross stage on linux/amd64 and push
#   cross_stage_build_local()        — build a cross stage locally (no push)
#   cross_stage_resolve_parent_pin() — resolve parent digest for stage transition
#   resolve_pin()                    — low-level pin resolution (captured → registry)
#   cross_stage_run()                — full orchestration: resolve parent, build, capture pin
#   cross_stage_assemble_runtime_helper_args() — build args for runtime helper invocation
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
# _cross_stage_build_impl
#
# Internal: build a cross-lane stage image on linux/amd64.
# When push=1: pushes to registry with cache registry support.
# When push=0: builds locally only (no push, no cache registry).
#
# Automatically disables --pull when BASE_IMAGE is already digest-pinned
# (repo@sha256:...), since the digest uniquely identifies the image and can
# never resolve to a stale version.
#
# Respects DRY_RUN (when set to a truthy value, prints the command without executing).
#
# Usage: _cross_stage_build_impl <push_flag> <label> <tag> <dockerfile> [extra build args...]
# ==============================================================================
_cross_stage_build_impl() {
  local push_flag="$1" label="$2" tag="$3" dockerfile="$4"
  shift 4
  local -a extra=("$@")
  local -a common_args=()
  append_common_build_args common_args

  local log_file
  log_file="$(cross_stage_log_redirect "${label}")"

  local pull_flag="--pull=true"
  if [ "${push_flag}" -eq 0 ]; then
    # Local builds use local images; registry may have stale versions.
    pull_flag="--pull=false"
  elif _has_digest_pinned_base "${extra[@]}"; then
    # Digest-pinned bases are immutable; no need to pull.
    pull_flag="--pull=false"
  fi

  local -a build_cmd=(
    "${NERDCTL_BIN:-nerdctl}" build
    "${pull_flag}"
    ${NO_CACHE:+--no-cache}
    --platform linux/amd64
    -t "${tag}"
    -f "${dockerfile}"
  )

  if [ "${push_flag}" -eq 1 ]; then
    build_cmd+=(
      --output "type=image,name=${tag},push=true"
    )
    # Supply-chain attestations (opt-in via BUILD_ATTEST=1): SLSA provenance +
    # an SBOM attached to the pushed image as OCI referrers. Off by default
    # because the SBOM scanner adds time to every stage; enable for release/
    # publish builds. nerdctl >=2 maps these to buildkit --attest.
    if [ -n "${BUILD_ATTEST:-}" ]; then
      build_cmd+=(
        --provenance=mode=max
        --sbom=true
      )
    fi
  fi

  # ---------------------------------------------------------------------------
  # Build cache. A LOCAL buildkit cache is primary: it survives repeated
  # rebuilds on the same host and never touches the registry, so it cannot hit
  # ghcr.io's "400 Bad Request" on oversized mode=max cache blobs.
  #
  # This replaces a self-defeating scheme: the old code added --cache-from
  # type=registry,ref=<tag>-buildcache always, but gated the matching
  # --cache-to behind NO_CACHE_EXPORT. With NO_CACHE_EXPORT=1 the -buildcache
  # ref was NEVER written, so --cache-from pointed at a ref that did not exist
  # -> BuildKit failed the importer and every stage rebuilt from scratch.
  #
  # A missing/empty local src is a clean cache miss, never an error, so this is
  # safe on the very first build. mode=max keeps intermediate-stage layers.
  # ---------------------------------------------------------------------------
  if [ -z "${NO_CACHE:-}" ]; then
    local _cache_dir _cache_slug
    _cache_dir="${BUILDKIT_CACHE_DIR:-${HOME:-/root}/.cache/kata-buildcache}"
    _cache_slug="$(printf '%s' "${tag}" | tr '/:@' '___')"
    mkdir -p "${_cache_dir}/${_cache_slug}" 2>/dev/null || true
    build_cmd+=(
      --cache-from "type=local,src=${_cache_dir}/${_cache_slug}"
      --cache-to "type=local,dest=${_cache_dir}/${_cache_slug},mode=max"
    )
    # When pushing, also ride an inline cache inside the image (mode=min,
    # embedded in the image config -> no separate blob, so no 400) and read it
    # back from the tag itself, letting other hosts warm-start from the
    # registry. NO_CACHE_EXPORT keeps the local cache but skips this
    # registry-facing export.
    if [ "${push_flag}" -eq 1 ] && [ -z "${NO_CACHE_EXPORT:-}" ]; then
      build_cmd+=(
        --cache-from "type=registry,ref=${tag}"
        --cache-to "type=inline"
      )
    fi
  fi

  append_buildkit_host_arg build_cmd
  build_cmd+=("${extra[@]}" "${common_args[@]}" .)

  if is_dry_run; then
    printf '[DRY RUN] '
    printf '%q ' "${build_cmd[@]}"
    printf '\n'
    return 0
  fi

  if [ -n "${log_file}" ]; then
    # Real pipe, not process substitution: the shell waits for tee to drain, so
    # a fast-failing build's tail is always flushed to the log. PIPESTATUS[0]
    # returns the BUILD's exit code (not tee's 0), independent of pipefail.
    run "${build_cmd[@]}" 2>&1 | tee -a "${log_file}"
    return "${PIPESTATUS[0]}"
  else
    run "${build_cmd[@]}"
  fi
}

# ==============================================================================
# cross_stage_build_and_push
#
# Build a cross-lane stage image on linux/amd64, push it to the registry.
#
# Uses registry build cache via --cache-from / --cache-to for faster rebuilds.
# Respects DRY_RUN (when set to 1, prints the command without executing).
#
# Usage: cross_stage_build_and_push <label> <tag> <dockerfile> [extra build args...]
# ==============================================================================
cross_stage_build_and_push() {
  _cross_stage_build_impl 1 "$@"
}

# ==============================================================================
# cross_stage_build_local
#
# Build a cross-lane stage image locally on linux/amd64 WITHOUT pushing.
# The image stays in the local containerd store.
#
# Respects DRY_RUN (when set to 1, prints the command without executing).
#
# Usage: cross_stage_build_local <label> <tag> <dockerfile> [extra build args...]
# ==============================================================================
cross_stage_build_local() {
  _cross_stage_build_impl 0 "$@"
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

  if is_dry_run; then
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
# Full cross-stage orchestration: resolve the parent reference, assemble build
# args, run the build (with or without push), and capture the output digest pin.
#
# Parameters:
#   $1  stage name (base|compiler|sdk|media|android)
#   $2  target architecture (required for per-arch stages; empty for base/compiler)
#   $3  push flag: 1 = build and push with digest pinning (default);
#       0 = build locally, no push, no pin capture
#
# When push=1:
#   - The parent is resolved via digest-pinned reference (registry digest or
#     captured in-run pin). This prevents stale base reuse.
#   - The stage image is pushed to the registry via cross_stage_build_and_push().
#   - The pushed digest is captured and stored in the appropriate pin variable
#     (BASE_PIN, COMPILER_PIN, SDK_PIN[arch], etc.) for downstream stages.
#
# When push=0:
#   - The parent is resolved via the mutable tag (safe for local-only builds
#     since no downstream stage will inherit from a stale image).
#   - The image stays local via cross_stage_build_local().
#   - No pin is captured.
#
# Pin capture is guarded: if the expected pin variable is not declared in the
# calling scope, the pin is logged but not stored (safe for standalone scripts).
#
# Usage:
#   cross_stage_run "media" "arm64"        # push (default)
#   cross_stage_run "compiler" "" 0        # local only
# ==============================================================================
# Resolve the parent image reference (digest-pinned for push, mutable tag for
# local) and append it to the build_args nameref. Returns the pinned ref on
# stdout (empty when local/no parent).
# Sets the resolved pin (empty for local/no-parent) into the global
# _CROSS_STAGE_PARENT_PIN. NOTE: this function MUST be called directly (not in a
# command substitution) — it mutates the build_args nameref in $1, and a $(...)
# subshell would discard that mutation, silently dropping --build-arg BASE_IMAGE
# and making the FROM fall back to the Dockerfile default. The pin is returned
# via a global instead of stdout precisely so the caller need not use $(...).
_cross_stage_run_resolve_parent() {
  local -n _csrrp_out="$1"
  local stage="$2" arch="$3" push_flag="$4" parent="$5"
  _CROSS_STAGE_PARENT_PIN=""

  if [ -z "${parent}" ]; then
    return 0
  fi

  if [ "${push_flag}" -eq 1 ]; then
    local parent_pin
    parent_pin="$(cross_stage_resolve_parent_pin "${stage}" "${arch}")" || {
      err "Failed to resolve parent pin for stage '${stage}' (parent: ${parent}). Ensure the parent image is pushed to the registry."
    }
    [ -n "${parent_pin}" ] && _csrrp_out+=(--build-arg "BASE_IMAGE=${parent_pin}")
    _CROSS_STAGE_PARENT_PIN="${parent_pin}"
  else
    local parent_tag
    parent_tag="$(cross_stage_tag "${parent}" "${arch}")"
    [ -z "${parent_tag}" ] && { err "No tag for parent stage: ${parent}"; }
    _csrrp_out+=(--build-arg "BASE_IMAGE=${parent_tag}")
  fi
}

# Dispatch the build to cross_stage_build_and_push (push) or
# cross_stage_build_local (local) based on the push_flag.
_cross_stage_run_dispatch() {
  local label="$1" tag="$2" dockerfile="$3" push_flag="$4"
  shift 4
  if [ "${push_flag}" -eq 1 ]; then
    cross_stage_build_and_push "${label}" "${tag}" "${dockerfile}" "$@"
  else
    cross_stage_build_local "${label}" "${tag}" "${dockerfile}" "$@"
  fi
}

# Capture the just-pushed image's registry digest and persist it into the
# stage's pin variable (per-arch associative array for per-arch stages, scalar
# for shared stages). Under --parallel-archs, also writes to the loop's flag dir
# so parallel_loop_harvest() can read it back into the parent shell.
_cross_stage_run_capture_pin() {
  local stage="$1" arch="$2" label="$3" tag="$4"

  local pin_varname
  pin_varname="$(cross_stage_pin_varname "${stage}")"
  [ -z "${pin_varname}" ] && { err "No pin varname for stage: ${stage}"; }

  local pinned_digest
  pinned_digest="$(retry 5 10 "registry digest for ${tag}" registry_pin_ref "${NERDCTL_BIN:-nerdctl}" "${tag}")"
  [ -z "${pinned_digest}" ] && { err "Failed to capture digest pin for ${tag}"; }

  if cross_stage_is_per_arch "${stage}"; then
    if ! declare -p "${pin_varname}" &>/dev/null; then
      log "[stage ${label}] pinned ${pinned_digest} (pin variable ${pin_varname} not in scope, skipping storage)"
    else
      local -n pin_map="${pin_varname}"
      pin_map["${arch}"]="${pinned_digest}"
      log "[stage ${label}] pinned ${pinned_digest}"
      local built_flag_varname="${stage^^}_BUILT_THIS_RUN"
      if declare -p "${built_flag_varname}" &>/dev/null; then
        local -n built_flag="${built_flag_varname}"
        built_flag["${arch}"]=1
      fi
      # Under --parallel-archs this function runs in a background SUBSHELL:
      # the array writes above are lost to the parent. Persist to the loop's
      # flag dir; parallel_loop_harvest() reads them back after the join.
      if [ -n "${PARALLEL_LOOP_FLAGDIR:-}" ] && [ -d "${PARALLEL_LOOP_FLAGDIR}" ]; then
        printf '%s' "${pinned_digest}" > "${PARALLEL_LOOP_FLAGDIR}/pin.${stage}.${arch}"
        : > "${PARALLEL_LOOP_FLAGDIR}/built.${stage}.${arch}"
      fi
    fi
  else
    if declare -p "${pin_varname}" &>/dev/null; then
      printf -v "${pin_varname}" '%s' "${pinned_digest}"
      log "[stage ${label}] pinned ${!pin_varname}"
    else
      log "[stage ${label}] pinned ${pinned_digest} (pin variable ${pin_varname} not in scope, skipping storage)"
    fi
  fi
}

cross_stage_run() {
  local stage="$1" arch="${2:-}" push_flag="${3:-1}"
  local label tag dockerfile parent parent_pin
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

  parent="$(cross_stage_parent "${stage}")"

  # Call directly (NOT via $(...)): the function mutates the build_args nameref;
  # a command-substitution subshell would discard that and drop BASE_IMAGE.
  _cross_stage_run_resolve_parent build_args "${stage}" "${arch}" "${push_flag}" "${parent}"
  parent_pin="${_CROSS_STAGE_PARENT_PIN}"

  # Append stage-specific build args from the stage graph
  cross_stage_build_args build_args "${stage}" "${arch}"

  log "[stage ${label}] building${tag:+ }${tag}${parent_pin:+ FROM ${parent_pin}}"
  if [ "${push_flag}" -eq 1 ]; then
    log "[stage ${label}] building ${tag}${parent_pin:+ FROM ${parent_pin}}"
    _cross_stage_run_dispatch "${label}" "${tag}" "${dockerfile}" 1 "${build_args[@]}"
  else
    log "[stage ${label}] building ${tag} locally"
    _cross_stage_run_dispatch "${label}" "${tag}" "${dockerfile}" 0 "${build_args[@]}"
  fi

  # Pin capture: only on push, and only when not a dry run
  if [ "${push_flag}" -eq 0 ]; then
    return 0
  fi
  if is_dry_run; then
    log "[stage ${label}] [DRY RUN] would pin ${tag}"
    return 0
  fi

  _cross_stage_run_capture_pin "${stage}" "${arch}" "${label}" "${tag}"
}

# Harvest hook for run_parallel_arch_loop: read worker-persisted digest pins
# and built-this-run flags back into the parent's arrays (background subshell
# writes are otherwise lost — the pins silently vanished under
# --parallel-archs before this existed).
parallel_loop_harvest() {
  local flagdir="$1" f name stage arch pin_varname built_varname
  for f in "${flagdir}"/pin.*.*; do
    [ -f "${f}" ] || continue
    name="${f##*/pin.}"
    stage="${name%%.*}"
    arch="${name##*.}"
    pin_varname="$(cross_stage_pin_varname "${stage}" 2>/dev/null || true)"
    [ -n "${pin_varname}" ] || continue
    if declare -p "${pin_varname}" &>/dev/null; then
      local -n _hv_pin_map="${pin_varname}"
      _hv_pin_map["${arch}"]="$(cat "${f}")"
      log "[stage ${stage}-${arch}] pin harvested from parallel worker"
    fi
    built_varname="${stage^^}_BUILT_THIS_RUN"
    if [ -f "${flagdir}/built.${stage}.${arch}" ] && declare -p "${built_varname}" &>/dev/null; then
      local -n _hv_built="${built_varname}"
      _hv_built["${arch}"]=1
    fi
  done
}

# ==============================================================================
# cross_stage_assemble_runtime_helper_args
#
# Build the argument array for build-runtime-manifest.sh from the orchestrator's
# state (IMAGE_REPO, FINAL_IMAGE, TARGET_ARCHES, mirror settings).
#
# Exists here so the orchestrator and the runtime helper share a single canonical
# source for the handoff interface.
#
# Usage: cross_stage_assemble_runtime_helper_args <nameref>
# ==============================================================================
cross_stage_assemble_runtime_helper_args() {
  local -n _arha_out=${1}
  _arha_out=(
    --image "${FINAL_IMAGE}"
    --target-arches "${TARGET_ARCHES}"
    --artifact-image-prefix "${IMAGE_REPO}:cross-android"
    --artifact-build-mode cross
    --push
  )
  if _bool_truthy "${USE_FAST_UBUNTU_MIRROR:-false}"; then
    _arha_out+=(--fast-ubuntu-mirror --fast-ubuntu-mirror-url "${FAST_UBUNTU_MIRROR_URL}")
    if [ -n "${FAST_UBUNTU_PORTS_MIRROR_URL:-}" ]; then
      _arha_out+=(--fast-ubuntu-ports-mirror-url "${FAST_UBUNTU_PORTS_MIRROR_URL}")
    fi
  fi
}
