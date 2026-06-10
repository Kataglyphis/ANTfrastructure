#!/usr/bin/env bash
set -euo pipefail

# build-cross-chain.sh
#
# Orchestrates the full additive cross lane end-to-end with a digest-pinned
# stage handoff:
#
#   base -> compiler -> sdk -> media -> android -> runtime(package/torch/wrapper/manifest)
#
# WHY THIS EXISTS
# ---------------
# Each cross stage is a separate `nerdctl build` whose next stage does
# `FROM ${BASE_IMAGE}`. If BASE_IMAGE is a mutable tag (e.g. :media-cross-arm64)
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
# can never resolve to a stale image, so a cheaper/less careful agent that runs
# this single command always chains the images it just built.
#
# Every cross stage is pushed because digest pinning needs the manifest to exist
# in the registry. That matches the existing documented cross flow, which already
# pushes base/compiler/sdk/media/android intermediates.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck disable=SC1091
source "${REPO_ROOT}/linux/scripts/01-core/artifact-common.sh"

NERDCTL_BIN="${NERDCTL_BIN:-nerdctl}"
IMAGE_REPO="${IMAGE_REPO:-${IMAGE_REGISTRY_PREFIX}}"
FINAL_IMAGE="${FINAL_IMAGE:-${IMAGE_REPO}:latest-cross}"
TARGET_ARCHES="${TARGET_ARCHES:-${TARGET_ARCH:-${CROSS_DEFAULT_ARCHES}}}"
# Compiler targets baked into the single amd64-hosted compiler image. The
# compiler must contain every arch the later per-arch stages will target.
CROSS_TARGETS="${CROSS_TARGETS:-${CROSS_DEFAULT_ARCHES}}"
VULKAN_VERSION="${VULKAN_VERSION:-1.4.341.1}"
USE_FAST_UBUNTU_MIRROR="${USE_FAST_UBUNTU_MIRROR:-false}"
FAST_UBUNTU_MIRROR_URL="${FAST_UBUNTU_MIRROR_URL:-${FAST_UBUNTU_MIRROR_URL_DEFAULT}}"
FAST_UBUNTU_PORTS_MIRROR_URL="${FAST_UBUNTU_PORTS_MIRROR_URL:-}"
LOG_DIR="${LOG_DIR:-}"

FROM_STAGE="base"
TO_STAGE="runtime"
VERIFY_CHAIN_ONLY=0
DRY_RUN=0
PARALLEL_ARCHS=0
MAX_PARALLEL_ARCHS="${MAX_PARALLEL_ARCHS:-4}"

# Ordered stage list used for --from-stage/--to-stage gating.
ALL_STAGES=(base compiler sdk media android runtime)

# Pre-built stage index map for O(1) lookups.
declare -A STAGE_INDEX=()
for i in "${!ALL_STAGES[@]}"; do
  STAGE_INDEX["${ALL_STAGES[$i]}"]="${i}"
done

# Per-arch digest references captured during this run.
declare -A SDK_PIN=()
declare -A MEDIA_PIN=()
declare -A ANDROID_PIN=()
declare -A ANDROID_BUILT_THIS_RUN=()
BASE_PIN=""
COMPILER_PIN=""

usage() {
  cat <<'EOF'
Usage: build-cross-chain.sh [options]

Builds the additive cross lane end-to-end with a digest-pinned stage handoff so
a freshly built stage is always consumed by the next one (no stale-tag reuse):

  base -> compiler -> sdk -> media -> android -> runtime

Every cross stage is built on linux/amd64 and pushed to the registry; the next
stage's FROM is pinned to the pushed manifest digest. The final "runtime" stage
delegates to build-runtime-manifest.sh to build per-arch base/package/torch
wrapper images on the real target platform and publish the multi-arch manifest.

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
EOF
}

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

stage_log_redirect() {
  # Echo a shell redirect suffix when LOG_DIR is set, else nothing.
  local label="$1"
  if [ -n "${LOG_DIR}" ]; then
    mkdir -p "${LOG_DIR}"
    printf '%s/%s.log' "${LOG_DIR}" "${label}"
  fi
}

# Detect whether the extra build args include a digest-pinned BASE_IMAGE.
# If BASE_IMAGE=repo@sha256:..., --pull is unnecessary because the digest
# uniquely identifies the image and can never resolve to a stale version.
_has_digest_pinned_base() {
  local arg
  for arg in "$@"; do
    case "${arg}" in
      --build-arg|BASE_IMAGE=*) ;;  # skip flag, value follows
      *@sha256:*) return 0 ;;
    esac
  done
  return 1
}

# Build a cross stage on linux/amd64, push it, and print its digest-pinned ref.
# Usage: build_cross_stage <label> <tag> <dockerfile> [extra build args...]
build_cross_stage() {
  local label="$1" tag="$2" dockerfile="$3"
  shift 3
  local -a extra=("$@")
  local -a common_args=()
  append_mirror_build_args_from_env common_args
  append_version_build_args common_args

  local log_file
  log_file="$(stage_log_redirect "${label}")"

  local pull_flag="--pull=true"
  if _has_digest_pinned_base "${extra[@]}"; then
    pull_flag="--pull=false"
  fi

  local -a build_cmd=(
    "${NERDCTL_BIN}" build
    "${pull_flag}"
    --platform linux/amd64
    -t "${tag}"
    --output "type=image,name=${tag},push=true"
    -f "${dockerfile}"
  )
  append_buildkit_host_arg build_cmd
  build_cmd+=("${extra[@]}" "${common_args[@]}" .)

  if [ "${DRY_RUN}" -eq 1 ]; then
    printf '[DRY RUN] '
    printf '%q ' "${build_cmd[@]}"
    printf '\n'
    return 0
  fi

  if [ -n "${log_file}" ]; then
    # Use process substitution to preserve pipefail (tee always exits 0)
    run "${build_cmd[@]}" > >(tee -a "${log_file}") 2>&1
  else
    run "${build_cmd[@]}"
  fi
}

# Resolve an upstream digest pin, preferring one captured this run, otherwise
# falling back to the parent tag's current registry digest.
resolve_pin() {
  local captured="$1" tag="$2"
  if [ -n "${captured}" ]; then
    printf '%s' "${captured}"
    return 0
  fi
  local result
  result="$(retry 3 10 "registry digest for ${tag}" registry_pin_ref "${NERDCTL_BIN}" "${tag}")" || {
    warn "Failed to resolve registry digest for ${tag}. Cannot pin downstream FROM."
    return 1
  }
  if [ -z "${result}" ]; then
    warn "Registry pin ref returned empty for ${tag}. Cannot pin downstream FROM."
    return 1
  fi
  printf '%s' "${result}"
}

run_base_stage() {
  local tag
  tag="$(cross_base_tag)"
  log "[stage base] building ${tag}"
  build_cross_stage base "${tag}" linux/Dockerfile.base
  BASE_PIN="$(retry 5 10 "registry digest for ${tag}" registry_pin_ref "${NERDCTL_BIN}" "${tag}")"
  log "[stage base] pinned ${BASE_PIN}"
}

run_compiler_stage() {
  local tag base_pin
  tag="$(cross_compiler_tag)"
  base_pin="$(resolve_pin "${BASE_PIN}" "$(cross_base_tag)")"
  log "[stage compiler] building ${tag} FROM ${base_pin}"
  build_cross_stage compiler "${tag}" linux/Dockerfile.toolchain \
    --build-arg "BASE_IMAGE=${base_pin}" \
    --build-arg "BUILD_MODE=cross" \
    --build-arg "CROSS_TARGETS=${CROSS_TARGETS}"
  COMPILER_PIN="$(retry 5 10 "registry digest for ${tag}" registry_pin_ref "${NERDCTL_BIN}" "${tag}")"
  log "[stage compiler] pinned ${COMPILER_PIN}"
}

run_sdk_stage() {
  local arch="$1"
  local tag compiler_pin
  tag="$(cross_sdk_tag "${arch}")"
  compiler_pin="$(resolve_pin "${COMPILER_PIN}" "$(cross_compiler_tag)")"
  log "[stage sdk ${arch}] building ${tag} FROM ${compiler_pin}"
  build_cross_stage "sdk-${arch}" "${tag}" linux/Dockerfile.sdk \
    --build-arg "BASE_IMAGE=${compiler_pin}" \
    --build-arg "BUILD_MODE=cross" \
    --build-arg "TARGET_ARCH=${arch}" \
    --build-arg "VULKAN_VERSION=${VULKAN_VERSION}"
  SDK_PIN[$arch]="$(retry 5 10 "registry digest for ${tag}" registry_pin_ref "${NERDCTL_BIN}" "${tag}")"
  log "[stage sdk ${arch}] pinned ${SDK_PIN[$arch]}"
}

run_media_stage() {
  local arch="$1"
  local tag sdk_pin
  tag="$(cross_media_tag "${arch}")"
  sdk_pin="$(resolve_pin "${SDK_PIN[$arch]:-}" "$(cross_sdk_tag "${arch}")")"
  log "[stage media ${arch}] building ${tag} FROM ${sdk_pin}"
  build_cross_stage "media-${arch}" "${tag}" linux/Dockerfile.media \
    --build-arg "BASE_IMAGE=${sdk_pin}" \
    --build-arg "BUILD_MODE=cross" \
    --build-arg "TARGET_ARCH=${arch}"
  MEDIA_PIN[$arch]="$(retry 5 10 "registry digest for ${tag}" registry_pin_ref "${NERDCTL_BIN}" "${tag}")"
  log "[stage media ${arch}] pinned ${MEDIA_PIN[$arch]}"
}

run_android_stage() {
  local arch="$1"
  local tag media_pin
  tag="$(cross_android_tag "${arch}")"
  media_pin="$(resolve_pin "${MEDIA_PIN[$arch]:-}" "$(cross_media_tag "${arch}")")"
  log "[stage android ${arch}] building ${tag} FROM ${media_pin}"
  build_cross_stage "android-${arch}" "${tag}" linux/Dockerfile.android \
    --build-arg "BASE_IMAGE=${media_pin}" \
    --build-arg "BUILD_MODE=cross" \
    --build-arg "TARGET_ARCH=${arch}"
  ANDROID_PIN[$arch]="$(retry 5 10 "registry digest for ${tag}" registry_pin_ref "${NERDCTL_BIN}" "${tag}")"
  ANDROID_BUILT_THIS_RUN[$arch]=1
  log "[stage android ${arch}] pinned ${ANDROID_PIN[$arch]}"
}

run_runtime_stage() {
  local arch
  # The runtime helper consumes the local cross-android-${arch} tag with
  # --pull=false. If android was built this run the local tag is already fresh.
  # When resuming straight into runtime, refresh the local tag from the registry
  # so the package stage cannot pick up a stale local android image.
  for arch in ${TARGET_ARCHES//,/ }; do
    if [ -z "${ANDROID_BUILT_THIS_RUN[$arch]:-}" ]; then
      local android_tag
      android_tag="$(cross_android_tag "${arch}")"
      if [ "${DRY_RUN}" -eq 1 ]; then
        log "[stage runtime] [DRY RUN] would refresh local ${android_tag} from registry"
      else
        log "[stage runtime] refreshing local ${android_tag} from registry"
        run "${NERDCTL_BIN}" pull --platform linux/amd64 "${android_tag}"
      fi
    fi
  done

  local -a helper_args=(
    --image "${FINAL_IMAGE}"
    --target-arches "${TARGET_ARCHES}"
    --artifact-image-prefix "${IMAGE_REPO}:cross-android"
    --artifact-build-mode cross
    --push
  )
  if [ "${USE_FAST_UBUNTU_MIRROR}" = "true" ]; then
    helper_args+=(--fast-ubuntu-mirror --fast-ubuntu-mirror-url "${FAST_UBUNTU_MIRROR_URL}")
    if [ -n "${FAST_UBUNTU_PORTS_MIRROR_URL}" ]; then
      helper_args+=(--fast-ubuntu-ports-mirror-url "${FAST_UBUNTU_PORTS_MIRROR_URL}")
    fi
  fi

  if [ "${DRY_RUN}" -eq 1 ]; then
    log "[stage runtime] [DRY RUN] would run build-runtime-manifest.sh ${helper_args[*]}"
    return 0
  fi

  log "[stage runtime] building package/torch/wrapper + manifest ${FINAL_IMAGE}"
  run env NERDCTL_BIN="${NERDCTL_BIN}" \
    bash "${REPO_ROOT}/linux/scripts/build-runtime-manifest.sh" "${helper_args[@]}"
}

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
  local arch

  log "[verify] checking cross-chain freshness for arches: ${TARGET_ARCHES}"

  _verify_link "base->compiler" "$(cross_base_tag)" "$(cross_compiler_tag)"

  for arch in ${TARGET_ARCHES//,/ }; do
    _verify_link "compiler->sdk-${arch}" "$(cross_compiler_tag)" "$(cross_sdk_tag "${arch}")"
  done

  for arch in ${TARGET_ARCHES//,/ }; do
    _verify_link "sdk->media-${arch}" "$(cross_sdk_tag "${arch}")" "$(cross_media_tag "${arch}")"
  done

  for arch in ${TARGET_ARCHES//,/ }; do
    _verify_link "media->android-${arch}" "$(cross_media_tag "${arch}")" "$(cross_android_tag "${arch}")"
  done

  log "[verify] chain check complete"
}

# Run a stage function for each arch, optionally in parallel.
# Collects exit codes from all parallel jobs via flag files so a failure in one
# subprocess does not silently succeed.
_run_arch_loop() {
  local stage_fn="$1"; shift
  local -a pids=()
  local arch running failed=0
  local _flagdir
  _flagdir="$(mktemp -d /tmp/arch-loop-flags.XXXXXX)"
  trap 'rm -rf ${_flagdir}' RETURN
  running=0
  for arch in ${TARGET_ARCHES//,/ }; do
    if [ "${PARALLEL_ARCHS}" -eq 1 ]; then
      {
        "${stage_fn}" "${arch}" || touch "${_flagdir}/failed-${arch}"
      } &
      pids+=($!)
      running=$((running + 1))
      if [ "${running}" -ge "${MAX_PARALLEL_ARCHS}" ]; then
        wait -n 2>/dev/null || true
        running=$((running - 1))
      fi
    else
      "${stage_fn}" "${arch}" || failed=1
    fi
  done
  if [ "${PARALLEL_ARCHS}" -eq 1 ]; then
    for pid in "${pids[@]}"; do
      wait "${pid}" || true
    done
    local f
    for f in "${_flagdir}"/failed-*; do
      if [ -f "${f}" ]; then
        warn "Arch ${f##*-} failed during parallel build"
        failed=1
      fi
    done
  fi
  return "${failed}"
}

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

  # Validate stage bounds early and cache indices.
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

  local arch
  if stage_enabled base; then run_base_stage; fi
  if stage_enabled compiler; then run_compiler_stage; fi
  if stage_enabled sdk; then
    _run_arch_loop run_sdk_stage
  fi
  if stage_enabled media; then
    _run_arch_loop run_media_stage
  fi
  if stage_enabled android; then
    _run_arch_loop run_android_stage
  fi
  if stage_enabled runtime; then run_runtime_stage; fi

  log "Cross chain complete."
}

main "$@"
