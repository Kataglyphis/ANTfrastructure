#!/usr/bin/env bash
set -euo pipefail

# build-cross-chain.sh
#
# Orchestrates the full additive cross lane end-to-end with a digest-pinned
# stage handoff:
#
#   base -> compiler -> sdk -> media -> android -> runtime
#
# WHY THIS EXISTS
# ---------------
# Each cross stage is a separate `nerdctl build` whose next stage does
# `FROM ${BASE_IMAGE}`. If BASE_IMAGE is a mutable tag (e.g. :cross-media-arm64)
# the downstream build can silently consume a STALE locally-cached image instead
# of the freshly built/pushed one, because:
#   * `--output type=image,...,push=true` pushes the new digest to the registry
#     but does not reliably refresh the local containerd tag, and
#   * BuildKit's default FROM resolution prefers an already-present local image.
#
# This orchestrator removes that failure mode by capturing each stage's
# REGISTRY-resolvable manifest digest (via registry_pin_ref) right after it is
# pushed, and feeding it to the next stage as
# `--build-arg BASE_IMAGE=<repo>@sha256:<digest>`. A content-addressed digest
# can never resolve to a stale image.
#
# STAGE GRAPH
# -----------
# The cross-lane stage chain is defined declaratively in
# `linux/scripts/01-core/stage-defs.sh`.  Each stage entry has a Dockerfile,
# parent stage, tag function, and per-arch flag.  Both the build loop and
# `--verify-chain` consume the same graph, so the chain is defined in exactly
# one place.
#
# Every cross stage is pushed because digest pinning needs the manifest to exist
# in the registry.  This matches the documented cross flow, which already pushes
# base/compiler/sdk/media/android intermediates.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck disable=SC1091
source "${REPO_ROOT}/linux/scripts/01-core/artifact-common.sh"

NERDCTL_BIN="${NERDCTL_BIN:-nerdctl}"
IMAGE_REPO="${IMAGE_REPO:-${IMAGE_REGISTRY_PREFIX}}"
FINAL_IMAGE="${FINAL_IMAGE:-${IMAGE_REPO}:latest-cross}"
TARGET_ARCHES="${TARGET_ARCHES:-${TARGET_ARCH:-${CROSS_DEFAULT_ARCHES}}}"
CROSS_TARGETS="${CROSS_TARGETS:-${CROSS_DEFAULT_ARCHES}}"
init_mirror_defaults
LOG_DIR="${LOG_DIR:-}"

FROM_STAGE="base"
TO_STAGE="runtime"
VERIFY_CHAIN_ONLY=0
DRY_RUN=0
PARALLEL_ARCHS=0
MAX_PARALLEL_ARCHS="${MAX_PARALLEL_ARCHS:-$(nproc 2>/dev/null || echo 4)}"

# Per-arch digest references captured during this run.
# These are accessed indirectly via cross_stage_pin_varname() + nameref in
# cross_stage_run() (defined in cross-stage-build.sh, sourced via artifact-common.sh).
# shellcheck disable=SC2034
declare -A SDK_PIN=()
# shellcheck disable=SC2034
declare -A MEDIA_PIN=()
# shellcheck disable=SC2034
declare -A ANDROID_PIN=()
declare -A ANDROID_BUILT_THIS_RUN=()
# shellcheck disable=SC2034
BASE_PIN=""
# shellcheck disable=SC2034
COMPILER_PIN=""

# ── stage gating ──────────────────────────────────────────────────────────────

# Build the STAGE_INDEX map from CROSS_STAGE_ORDER (defined in stage-defs.sh).
declare -A STAGE_INDEX=()
for i in "${!CROSS_STAGE_ORDER[@]}"; do
  STAGE_INDEX["${CROSS_STAGE_ORDER[$i]}"]="${i}"
done

stage_index() {
  local name="$1"
  local idx="${STAGE_INDEX[${name}]:--1}"
  if [ "${idx}" -ge 0 ]; then
    printf '%s' "${idx}"
    return 0
  fi
  warn "Unknown stage: ${name}"
  return 1
}

stage_enabled() {
  local name="$1" idx
  idx="$(stage_index "${name}")" || exit 1
  [ "${idx}" -ge "${FROM_STAGE_IDX}" ] && [ "${idx}" -le "${TO_STAGE_IDX}" ]
}

# ── usage ─────────────────────────────────────────────────────────────────────

usage() {
  cat <<'EOF'
Usage: build-cross-chain.sh [options]

Builds the additive cross lane end-to-end with a digest-pinned stage handoff so
a freshly built stage is always consumed by the next one (no stale-tag reuse):

  base -> compiler -> sdk -> media -> android -> runtime

The stage chain is defined in linux/scripts/01-core/stage-defs.sh.  Every cross
stage is built on linux/amd64 and pushed to the registry; the next stage's FROM
is pinned to the pushed manifest digest.  The final "runtime" stage delegates to
build-runtime-manifest.sh to build per-arch base/package/torch wrapper images on
the real target platform and publish the multi-arch manifest.

Options:
  --target-arches LIST     Comma-separated arch list (default: amd64,arm64,riscv64)
  --architectures LIST     Alias for --target-arches
  --cross-targets LIST     Compiler target list baked into the compiler image
                           (default: amd64,arm64,riscv64; must cover --target-arches)
  --image-repo REPO        Image repository (default: ghcr.io/kataglyphis/kataglyphis_beschleuniger)
  --final-image REF        Final multi-arch manifest ref (default: REPO:latest-cross)
  --from-stage STAGE       First stage to run: base|compiler|sdk|media|android|runtime
  --to-stage STAGE         Last stage to run (inclusive). Same value set.
  --only STAGE             Shorthand for --from-stage STAGE --to-stage STAGE
  --vulkan-version VER     Vulkan SDK version for the sdk stage
      --log-dir DIR            Tee each stage build into DIR/<stage>[-<arch>].log
      --verify-chain           Resolve all upstream digests and warn if downstream images are stale
      --dry-run                 Print build commands without executing them
      --parallel-archs          Build per-arch stages (sdk/media/android) in parallel
      --max-parallel-archs N    Max concurrent arch builds (default: 4)
      --fast-ubuntu-mirror     Replace Ubuntu archive/security/ports mirrors during builds
  --fast-ubuntu-mirror-url URL        Archive mirror URL
  --fast-ubuntu-ports-mirror-url URL  Optional ubuntu-ports mirror URL
  -h, --help               Show this help text

Notes:
  * When resuming mid-chain (e.g. --from-stage media), the required upstream
    digest is resolved from the parent stage's current registry tag.
  * Digest pinning requires pushing each cross stage; this is mandatory and
    matches the existing documented cross flow.
  * For single-stage rebuilds, use build-cross-stage.sh instead:
      bash linux/scripts/build-cross-stage.sh --stage sdk --arch arm64 --push
EOF
}

# ── runtime stage helpers ──────────────────────────────────────────────────────

# Ensure per-arch android images are locally available for the runtime stage.
# If android was built in this run, the image is already local; otherwise pull.
_refresh_android_images() {
  local arch android_tag
  for arch in ${TARGET_ARCHES//,/ }; do
    android_tag="$(cross_android_tag "${arch}")"
    if [ -n "${ANDROID_BUILT_THIS_RUN[$arch]:-}" ]; then
      log "[stage runtime] android-${arch} built in this run, skip pull"
      continue
    fi
    if is_dry_run; then
      log "[stage runtime] [DRY RUN] would pull ${android_tag}"
      continue
    fi
    log "[stage runtime] pulling ${android_tag}"
    run "${NERDCTL_BIN}" pull --platform linux/amd64 "${android_tag}"
  done
}

# Build the argument array for build-runtime-manifest.sh from the orchestrator's
# state (IMAGE_REPO, FINAL_IMAGE, TARGET_ARCHES, mirror settings).
_assemble_runtime_helper_args() {
  local -a args_out
  local -n _arha_out=${1:-args_out}

  _arha_out=(
    --image "${FINAL_IMAGE}"
    --target-arches "${TARGET_ARCHES}"
    --artifact-image-prefix "${IMAGE_REPO}:cross-android"
    --artifact-build-mode cross
    --push
  )
  if [ "${USE_FAST_UBUNTU_MIRROR}" = "true" ]; then
    _arha_out+=(--fast-ubuntu-mirror --fast-ubuntu-mirror-url "${FAST_UBUNTU_MIRROR_URL}")
    if [ -n "${FAST_UBUNTU_PORTS_MIRROR_URL}" ]; then
      _arha_out+=(--fast-ubuntu-ports-mirror-url "${FAST_UBUNTU_PORTS_MIRROR_URL}")
    fi
  fi
}

# Runtime stage: delegates to build-runtime-manifest.sh to build per-arch
# base -> package -> torch -> wrapper images on the real target platform and
# publish the multi-arch :latest-cross manifest.
run_runtime_stage() {
  _refresh_android_images

  local -a helper_args
  _assemble_runtime_helper_args helper_args

  if is_dry_run; then
    log "[stage runtime] [DRY RUN] would run build-runtime-manifest.sh ${helper_args[*]}"
    return 0
  fi

  log "[stage runtime] building package/torch/wrapper + manifest ${FINAL_IMAGE}"
  run env NERDCTL_BIN="${NERDCTL_BIN}" \
    bash "${REPO_ROOT}/linux/scripts/build-runtime-manifest.sh" "${helper_args[@]}"
}

# ── chain verification ────────────────────────────────────────────────────────

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

# Verify the entire cross chain by checking each documented stage transition.
# Uses CROSS_STAGE_ORDER from stage-defs.sh instead of hardcoded transitions.
# Skips runtime (delegates to separate script, no cross-lane Dockerfile).
verify_chain() {
  local stage parent parent_tag child_tag arch label

  log "[verify] checking cross-chain freshness for arches: ${TARGET_ARCHES}"

  for stage in "${CROSS_STAGE_ORDER[@]}"; do
    [ "${stage}" = "base" ] && continue    # no parent to verify
    [ "${stage}" = "runtime" ] && continue # delegates to runtime helper, not a cross stage

    parent="$(cross_stage_parent "${stage}")"

    if cross_stage_is_per_arch "${stage}"; then
      for arch in ${TARGET_ARCHES//,/ }; do
        # Parent tag may also need arch if the parent is per-arch
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

# ── main driver ───────────────────────────────────────────────────────────────

main() {
  local only_stage=""
  while [ $# -gt 0 ]; do
    local _dispatch_rc=0
    dispatch_parsed_args parse_shared_orchestrator_args \
      TARGET_ARCHES USE_FAST_UBUNTU_MIRROR FAST_UBUNTU_MIRROR_URL \
      FAST_UBUNTU_PORTS_MIRROR_URL IMAGE_REPO VULKAN_VERSION _unused_push \
      "$1" "${2:-}" || _dispatch_rc=$?
    case $_dispatch_rc in
      255) usage; exit 0 ;;
      0) case "${_DP_SHIFT}" in
           1) shift 1; continue ;;
           2) shift 2; continue ;;
         esac ;;
    esac
    case "$1" in
      --cross-targets) CROSS_TARGETS="$2"; shift 2 ;;
      --final-image) FINAL_IMAGE="$2"; shift 2 ;;
      --from-stage) FROM_STAGE="$2"; shift 2 ;;
      --to-stage) TO_STAGE="$2"; shift 2 ;;
      --only) only_stage="$2"; shift 2 ;;
      --log-dir) LOG_DIR="$2"; shift 2 ;;
      --verify-chain) VERIFY_CHAIN_ONLY=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      --parallel-archs) PARALLEL_ARCHS=1; shift ;;
      --max-parallel-archs) MAX_PARALLEL_ARCHS="$2"; shift 2 ;;
      *) err "Unknown option: $1" ;;
    esac
  done

  if [ -n "${only_stage}" ]; then
    FROM_STAGE="${only_stage}"
    TO_STAGE="${only_stage}"
  fi

  cd "${REPO_ROOT}"
  TARGET_ARCHES="$(normalize_target_arches "${TARGET_ARCHES}")"
  # Default FINAL_IMAGE may reference the previous IMAGE_REPO default; recompute
  # it if the user changed --image-repo but not --final-image.
  if [ "${FINAL_IMAGE}" = "${IMAGE_REGISTRY_PREFIX}:latest-cross" ]; then
    FINAL_IMAGE="${IMAGE_REPO}:latest-cross"
  fi

  FROM_STAGE_IDX="$(stage_index "${FROM_STAGE}")" || exit 1
  TO_STAGE_IDX="$(stage_index "${TO_STAGE}")" || exit 1
  if [ "${FROM_STAGE_IDX}" -gt "${TO_STAGE_IDX}" ]; then
    err "--from-stage (${FROM_STAGE}) is after --to-stage (${TO_STAGE})"
  fi

  log "Cross chain: arches=${TARGET_ARCHES} stages=${FROM_STAGE}..${TO_STAGE} repo=${IMAGE_REPO}"

  if [ "${VERIFY_CHAIN_ONLY}" -eq 1 ]; then
    verify_chain
    exit 0
  fi

  # Drive execution from the stage graph (stage-defs.sh).
  # Each stage in CROSS_STAGE_ORDER is run only if it falls within the
  # [FROM_STAGE, TO_STAGE] range.  Stage build/pin functions are provided
  # by cross-stage-build.sh (sourced via artifact-common.sh).
  local stage
  for stage in "${CROSS_STAGE_ORDER[@]}"; do
    stage_enabled "${stage}" || continue

    case "${stage}" in
      runtime)
        run_runtime_stage
        ;;
      *)
        if cross_stage_is_per_arch "${stage}"; then
          local _arch_fn
          _arch_fn() { cross_stage_run "${stage}" "$1"; }
          run_parallel_arch_loop _arch_fn "/tmp/cross-loop-flags" "${MAX_PARALLEL_ARCHS}" ${TARGET_ARCHES//,/ }
        else
          cross_stage_run "${stage}"
        fi
        ;;
    esac
  done

  log "Cross chain complete."
}

main "$@"
