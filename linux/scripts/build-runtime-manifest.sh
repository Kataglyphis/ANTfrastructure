#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck disable=SC1091
source "${REPO_ROOT}/linux/scripts/01-core/artifact-common.sh"

NERDCTL_BIN="${NERDCTL_BIN:-nerdctl}"
IMAGE_NAME="${IMAGE_NAME:-}"
ARCHITECTURES="${ARCHITECTURES:-${TARGET_ARCHES:-${TARGET_ARCH:-${CROSS_DEFAULT_ARCHES}}}}"
ARTIFACT_IMAGE_PREFIX="${ARTIFACT_IMAGE_PREFIX:-${IMAGE_REGISTRY_PREFIX}:cross-android}"
ARTIFACT_BUILD_MODE="${ARTIFACT_BUILD_MODE:-cross}"
BASE_DOCKERFILE_PATH="${BASE_DOCKERFILE_PATH:-linux/Dockerfile.base}"
PACKAGE_DOCKERFILE_PATH="${PACKAGE_DOCKERFILE_PATH:-linux/Dockerfile.package}"
WRAPPER_DOCKERFILE_PATH="${WRAPPER_DOCKERFILE_PATH:-linux/Dockerfile.torch}"
TORCH_APP_MODE="${TORCH_APP_MODE:-}"
init_mirror_defaults

PUSH_IMAGES=0
PUSH_MANIFEST=0
PUSH_INTERMEDIATE_IMAGES=0
BUILD_IMAGES=1
CREATE_MANIFEST=1
PARALLEL_ARCHS=0
MAX_PARALLEL_ARCHS="${MAX_PARALLEL_ARCHS:-4}"

usage() {
  cat <<'EOF'
Usage: build-runtime-manifest.sh --image IMAGE [options]

Builds the documented cross publish flow end-to-end:
1. clean per-architecture base images
2. package images that layer target-built payload from cross-android-${arch}
3. final wrapper images (includes torch venv + app + runtime scripts)
4. one multi-architecture manifest

Options:
  --image IMAGE                Final manifest image ref to build (required)
  --push-images                Push per-architecture wrapper images only
  --push-all                   Push ALL images (wrapper + base/package intermediates)
  --push-manifest              Push the final manifest after creating it
  --skip-manifest              Build images only; do not create a manifest locally
  --manifest-only              Create/push the manifest only; skip all image builds
  --push                       Short for --push-images --push-manifest (intermediates stay local)
  --parallel-archs              Build per-architecture images in parallel
  --max-parallel-archs N        Max concurrent arch builds (default: 4)
  -h, --help                   Show this help text
  --target-arches LIST          Comma-separated target list (default: amd64,arm64,riscv64)
  --architectures LIST          Alias for --target-arches
  --image-prefix TAG            Prefix for built wrapper image tags
  --artifact-image-prefix TAG   Cross tag prefix, or exact artifact image ref in native mode
  --artifact-build-mode MODE    Artifact source mode: cross or native (default: cross)
  --base-dockerfile PATH        Base Dockerfile (default: linux/Dockerfile.base)
  --package-dockerfile PATH     Package Dockerfile (default: linux/Dockerfile.package)
  --torch-dockerfile PATH       Alias for --wrapper-dockerfile (deprecated)
  --wrapper-dockerfile PATH     Final wrapper Dockerfile (default: linux/Dockerfile.torch)
  --torch-app-mode MODE         TORCH_APP_MODE for linux/Dockerfile.torch
  --fast-ubuntu-mirror          Replace Ubuntu archive/security/ports mirrors during Docker builds
  --fast-ubuntu-mirror-url URL  Archive mirror URL to use with --fast-ubuntu-mirror
  --fast-ubuntu-ports-mirror-url URL
                                 Optional mirror URL for ubuntu-ports entries
EOF
  cat <<'EOF'
Environment overrides:
  IMAGE_NAME                   Final manifest image ref, equivalent to --image
  NERDCTL_BIN                  nerdctl executable to use
  BUILDKIT_HOST                Optional BuildKit socket/address passed to nerdctl build
  TARGET_ARCHES                Comma-separated architecture list
  TARGET_ARCH                  Alias for TARGET_ARCHES
  ARCHITECTURES                Alias for TARGET_ARCHES
  RUNTIME_USE_LOCAL_CONTEXT_CHAIN
                                true/false/auto (default: auto)
  RUNTIME_CONTEXT_ROOT         Temporary directory root for local stage handoff
  BASE_DOCKERFILE_PATH         Base Dockerfile path
  BASE_PARENT_IMAGE            Optional parent image passed as BASE_IMAGE to the
                                selected base Dockerfile (for example a GPU base)
  PACKAGE_DOCKERFILE_PATH      Package Dockerfile path
  TORCH_DOCKERFILE_PATH        Torch Dockerfile path
  WRAPPER_DOCKERFILE_PATH      Final wrapper Dockerfile path
  TORCH_APP_MODE               TORCH_APP_MODE passed to linux/Dockerfile.torch
  ENABLE_NVIDIA                Optional accelerator flag passed to package/torch/wrapper builds
  ENABLE_AMD                   Optional accelerator flag passed to package/torch/wrapper builds
  ONNX_PACKAGE                 Optional torch ONNX package override
  PYTORCH_EXTRA                Optional torch PyTorch extra override
  USE_FAST_UBUNTU_MIRROR       Set to true to replace archive/security/ports Ubuntu mirrors
  FAST_UBUNTU_MIRROR_URL       Mirror URL used when the fast mirror is enabled
  FAST_UBUNTU_PORTS_MIRROR_URL Optional ports mirror URL used when the fast mirror is enabled
EOF
}

create_manifest() {
  local refs=()
  local arch

  for arch in ${ARCHITECTURES//,/ }; do
    refs+=("$(runtime_wrapper_tag "${arch}")")
  done

  if "${NERDCTL_BIN}" manifest inspect "${IMAGE_NAME}" >/dev/null 2>&1; then
    "${NERDCTL_BIN}" manifest rm "${IMAGE_NAME}" >/dev/null 2>&1 || true
  fi
  run "${NERDCTL_BIN}" manifest create "${IMAGE_NAME}" "${refs[@]}"

  if [ "${PUSH_MANIFEST}" -eq 1 ]; then
    run "${NERDCTL_BIN}" manifest push --purge "${IMAGE_NAME}"
  fi
}

_runtime_build_loop() {
  local -a pids=()
  local arch running failed=0
  local _flagdir
  _flagdir="$(mktemp -d /tmp/runtime-arch-loop-flags.XXXXXX)"
  trap "rm -rf ${_flagdir}" RETURN
  running=0
  for arch in ${ARCHITECTURES//,/ }; do
    if [ "${PARALLEL_ARCHS}" -eq 1 ]; then
      {
        runtime_build_chain "${arch}" || touch "${_flagdir}/failed-${arch}"
      } &
      pids+=($!)
      running=$((running + 1))
      if [ "${running}" -ge "${MAX_PARALLEL_ARCHS}" ]; then
        wait -n 2>/dev/null || true
        running=$((running - 1))
      fi
    else
      runtime_build_chain "${arch}" || failed=1
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
  while [ $# -gt 0 ]; do
    local _dispatch_rc=0
    runtime_dispatch_shared_args \
      ARCHITECTURES ARTIFACT_IMAGE_PREFIX ARTIFACT_BUILD_MODE \
      BASE_DOCKERFILE_PATH PACKAGE_DOCKERFILE_PATH WRAPPER_DOCKERFILE_PATH \
      TORCH_APP_MODE \
      USE_FAST_UBUNTU_MIRROR FAST_UBUNTU_MIRROR_URL FAST_UBUNTU_PORTS_MIRROR_URL \
      PUSH_INTERMEDIATE_IMAGES \
      "$1" "${2:-}" || _dispatch_rc=$?
    case $_dispatch_rc in
      255) usage; exit 0 ;;
      0) case "${_DP_SHIFT}" in
           1) shift 1; continue ;;
           2) shift 2; continue ;;
         esac ;;
    esac
    case "$1" in
      --image)
        IMAGE_NAME="$2"
        shift 2
        ;;
      --push-images)
        PUSH_IMAGES=1
        shift
        ;;
      --push-manifest)
        PUSH_MANIFEST=1
        shift
        ;;
      --skip-manifest)
        CREATE_MANIFEST=0
        shift
        ;;
      --manifest-only)
        BUILD_IMAGES=0
        shift
        ;;
      --push)
        PUSH_IMAGES=1
        PUSH_MANIFEST=1
        shift
        ;;
      --push-all)
        PUSH_IMAGES=1
        PUSH_MANIFEST=1
        PUSH_INTERMEDIATE_IMAGES=1
        shift
        ;;
      --parallel-archs)
        PARALLEL_ARCHS=1
        shift
        ;;
      --max-parallel-archs)
        MAX_PARALLEL_ARCHS="$2"
        shift 2
        ;;
      *)
        err "Unknown option: $1"
        ;;
    esac
  done

  if [ -z "${IMAGE_NAME}" ]; then
    err "--image is required"
  fi

  runtime_post_parse_setup ARCHITECTURES "${IMAGE_NAME}"

  if [ "${BUILD_IMAGES}" -eq 1 ]; then
    log "Building ${ARTIFACT_BUILD_MODE} runtime package flow for architectures: ${ARCHITECTURES}"
  else
    log "Creating manifest only for architectures: ${ARCHITECTURES}"
  fi

  local arch
  if [ "${BUILD_IMAGES}" -eq 1 ]; then
    _runtime_build_loop
  fi

  if [ "${CREATE_MANIFEST}" -eq 1 ]; then
    create_manifest
  fi
}

main "$@"
