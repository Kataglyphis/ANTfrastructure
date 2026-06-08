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
TARGET_ARCHES="${TARGET_ARCHES:-${TARGET_ARCH:-amd64,arm64,riscv64}}"
# Compiler targets baked into the single amd64-hosted compiler image. The
# compiler must contain every arch the later per-arch stages will target.
CROSS_TARGETS="${CROSS_TARGETS:-amd64,arm64,riscv64}"
VULKAN_VERSION="${VULKAN_VERSION:-1.4.341.1}"
USE_FAST_UBUNTU_MIRROR="${USE_FAST_UBUNTU_MIRROR:-false}"
FAST_UBUNTU_MIRROR_URL="${FAST_UBUNTU_MIRROR_URL:-https://archive.ubuntu.com/ubuntu/}"
FAST_UBUNTU_PORTS_MIRROR_URL="${FAST_UBUNTU_PORTS_MIRROR_URL:-}"
LOG_DIR="${LOG_DIR:-}"

FROM_STAGE="base"
TO_STAGE="runtime"

# Ordered stage list used for --from-stage/--to-stage gating.
ALL_STAGES=(base compiler sdk media android runtime)

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
  local name="$1" i
  for i in "${!ALL_STAGES[@]}"; do
    if [ "${ALL_STAGES[$i]}" = "${name}" ]; then
      printf '%s' "${i}"
      return 0
    fi
  done
  printf '[ERROR] Unknown stage: %s\n' "${name}" >&2
  return 1
}

stage_enabled() {
  local name="$1" idx from_idx to_idx
  idx="$(stage_index "${name}")" || exit 1
  from_idx="$(stage_index "${FROM_STAGE}")" || exit 1
  to_idx="$(stage_index "${TO_STAGE}")" || exit 1
  [ "${idx}" -ge "${from_idx}" ] && [ "${idx}" -le "${to_idx}" ]
}

stage_log_redirect() {
  # Echo a shell redirect suffix when LOG_DIR is set, else nothing.
  local label="$1"
  if [ -n "${LOG_DIR}" ]; then
    mkdir -p "${LOG_DIR}"
    printf '%s/%s.log' "${LOG_DIR}" "${label}"
  fi
}

# Build a cross stage on linux/amd64, push it, and print its digest-pinned ref.
# Usage: build_cross_stage <label> <tag> <dockerfile> [extra build args...]
build_cross_stage() {
  local label="$1" tag="$2" dockerfile="$3"
  shift 3
  local -a extra=("$@")
  local -a mirror_args=()
  local -a version_args=()
  append_mirror_build_args mirror_args "${USE_FAST_UBUNTU_MIRROR}" "${FAST_UBUNTU_MIRROR_URL}" "${FAST_UBUNTU_PORTS_MIRROR_URL}"
  append_version_build_args version_args

  local log_file
  log_file="$(stage_log_redirect "${label}")"

  local -a build_cmd=(
    "${NERDCTL_BIN}" build
    --pull=true
    --platform linux/amd64
    -t "${tag}"
    --output "type=image,name=${tag},push=true"
    -f "${dockerfile}"
  )
  append_buildkit_host_arg build_cmd
  build_cmd+=("${extra[@]}" "${mirror_args[@]}" "${version_args[@]}" .)

  if [ -n "${log_file}" ]; then
    run "${build_cmd[@]}" 2>&1 | tee "${log_file}"
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
  registry_pin_ref "${NERDCTL_BIN}" "${tag}"
}

run_base_stage() {
  local tag="${IMAGE_REPO}:base"
  log "[stage base] building ${tag}"
  build_cross_stage base "${tag}" linux/Dockerfile.base
  BASE_PIN="$(registry_pin_ref "${NERDCTL_BIN}" "${tag}")"
  log "[stage base] pinned ${BASE_PIN}"
}

run_compiler_stage() {
  local tag="${IMAGE_REPO}:compiler-cross-amd64"
  local base_pin
  base_pin="$(resolve_pin "${BASE_PIN}" "${IMAGE_REPO}:base")"
  log "[stage compiler] building ${tag} FROM ${base_pin}"
  build_cross_stage compiler "${tag}" linux/Dockerfile.toolchain \
    --build-arg "BASE_IMAGE=${base_pin}" \
    --build-arg "BUILD_MODE=cross" \
    --build-arg "CROSS_TARGETS=${CROSS_TARGETS}"
  COMPILER_PIN="$(registry_pin_ref "${NERDCTL_BIN}" "${tag}")"
  log "[stage compiler] pinned ${COMPILER_PIN}"
}

run_sdk_stage() {
  local arch="$1"
  local tag="${IMAGE_REPO}:sdk-artifact-${arch}"
  local compiler_pin
  compiler_pin="$(resolve_pin "${COMPILER_PIN}" "${IMAGE_REPO}:compiler-cross-amd64")"
  log "[stage sdk ${arch}] building ${tag} FROM ${compiler_pin}"
  build_cross_stage "sdk-${arch}" "${tag}" linux/Dockerfile.sdk \
    --build-arg "BASE_IMAGE=${compiler_pin}" \
    --build-arg "BUILD_MODE=cross" \
    --build-arg "TARGET_ARCH=${arch}" \
    --build-arg "VULKAN_VERSION=${VULKAN_VERSION}"
  SDK_PIN[$arch]="$(registry_pin_ref "${NERDCTL_BIN}" "${tag}")"
  log "[stage sdk ${arch}] pinned ${SDK_PIN[$arch]}"
}

run_media_stage() {
  local arch="$1"
  local tag="${IMAGE_REPO}:media-cross-${arch}"
  local sdk_pin
  sdk_pin="$(resolve_pin "${SDK_PIN[$arch]:-}" "${IMAGE_REPO}:sdk-artifact-${arch}")"
  log "[stage media ${arch}] building ${tag} FROM ${sdk_pin}"
  build_cross_stage "media-${arch}" "${tag}" linux/Dockerfile.media \
    --build-arg "BASE_IMAGE=${sdk_pin}" \
    --build-arg "BUILD_MODE=cross" \
    --build-arg "TARGET_ARCH=${arch}"
  MEDIA_PIN[$arch]="$(registry_pin_ref "${NERDCTL_BIN}" "${tag}")"
  log "[stage media ${arch}] pinned ${MEDIA_PIN[$arch]}"
}

run_android_stage() {
  local arch="$1"
  local tag="${IMAGE_REPO}:android-cross-${arch}"
  local media_pin
  media_pin="$(resolve_pin "${MEDIA_PIN[$arch]:-}" "${IMAGE_REPO}:media-cross-${arch}")"
  log "[stage android ${arch}] building ${tag} FROM ${media_pin}"
  build_cross_stage "android-${arch}" "${tag}" linux/Dockerfile.android \
    --build-arg "BASE_IMAGE=${media_pin}" \
    --build-arg "BUILD_MODE=cross" \
    --build-arg "TARGET_ARCH=${arch}"
  ANDROID_PIN[$arch]="$(registry_pin_ref "${NERDCTL_BIN}" "${tag}")"
  ANDROID_BUILT_THIS_RUN[$arch]=1
  log "[stage android ${arch}] pinned ${ANDROID_PIN[$arch]}"
}

run_runtime_stage() {
  local arch
  # The runtime helper consumes the local android-cross-${arch} tag with
  # --pull=false. If android was built this run the local tag is already fresh.
  # When resuming straight into runtime, refresh the local tag from the registry
  # so the package stage cannot pick up a stale local android image.
  for arch in ${TARGET_ARCHES//,/ }; do
    if [ -z "${ANDROID_BUILT_THIS_RUN[$arch]:-}" ]; then
      log "[stage runtime] refreshing local android-cross-${arch} from registry"
      run "${NERDCTL_BIN}" pull --platform linux/amd64 "${IMAGE_REPO}:android-cross-${arch}"
    fi
  done

  local -a helper_args=(
    --image "${FINAL_IMAGE}"
    --target-arches "${TARGET_ARCHES}"
    --artifact-image-prefix "${IMAGE_REPO}:android-cross"
    --artifact-build-mode cross
    --push
  )
  if [ "${USE_FAST_UBUNTU_MIRROR}" = "true" ]; then
    helper_args+=(--fast-ubuntu-mirror --fast-ubuntu-mirror-url "${FAST_UBUNTU_MIRROR_URL}")
    if [ -n "${FAST_UBUNTU_PORTS_MIRROR_URL}" ]; then
      helper_args+=(--fast-ubuntu-ports-mirror-url "${FAST_UBUNTU_PORTS_MIRROR_URL}")
    fi
  fi

  log "[stage runtime] building package/torch/wrapper + manifest ${FINAL_IMAGE}"
  run env NERDCTL_BIN="${NERDCTL_BIN}" \
    bash "${REPO_ROOT}/linux/scripts/build-runtime-manifest.sh" "${helper_args[@]}"
}

main() {
  local only_stage=""
  while [ $# -gt 0 ]; do
    local oa_rc=0
    parse_shared_orchestrator_args \
      TARGET_ARCHES USE_FAST_UBUNTU_MIRROR FAST_UBUNTU_MIRROR_URL \
      FAST_UBUNTU_PORTS_MIRROR_URL IMAGE_REPO VULKAN_VERSION PUSH_IGNORED \
      "$1" "$2" || true
    oa_rc=$?
    case ${oa_rc} in
      2) shift 2; continue ;;
      1) shift 1; continue ;;
      255) usage; exit 0 ;;
    esac
    case "$1" in
      --cross-targets) CROSS_TARGETS="$2"; shift 2 ;;
      --final-image) FINAL_IMAGE="$2"; shift 2 ;;
      --from-stage) FROM_STAGE="$2"; shift 2 ;;
      --to-stage) TO_STAGE="$2"; shift 2 ;;
      --only) only_stage="$2"; shift 2 ;;
      --log-dir) LOG_DIR="$2"; shift 2 ;;
      *) printf '[ERROR] Unknown option: %s\n' "$1" >&2; usage >&2; exit 1 ;;
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

  # Validate stage bounds early.
  stage_index "${FROM_STAGE}" >/dev/null
  stage_index "${TO_STAGE}" >/dev/null
  if [ "$(stage_index "${FROM_STAGE}")" -gt "$(stage_index "${TO_STAGE}")" ]; then
    printf '[ERROR] --from-stage (%s) is after --to-stage (%s)\n' "${FROM_STAGE}" "${TO_STAGE}" >&2
    exit 1
  fi

  log "Cross chain: arches=${TARGET_ARCHES} stages=${FROM_STAGE}..${TO_STAGE} repo=${IMAGE_REPO}"

  local arch
  if stage_enabled base; then run_base_stage; fi
  if stage_enabled compiler; then run_compiler_stage; fi
  if stage_enabled sdk; then
    for arch in ${TARGET_ARCHES//,/ }; do run_sdk_stage "${arch}"; done
  fi
  if stage_enabled media; then
    for arch in ${TARGET_ARCHES//,/ }; do run_media_stage "${arch}"; done
  fi
  if stage_enabled android; then
    for arch in ${TARGET_ARCHES//,/ }; do run_android_stage "${arch}"; done
  fi
  if stage_enabled runtime; then run_runtime_stage; fi

  log "Cross chain complete."
}

main "$@"
