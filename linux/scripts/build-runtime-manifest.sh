#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

NERDCTL_BIN="${NERDCTL_BIN:-nerdctl}"
ARTIFACTS_ROOT="${ARTIFACTS_ROOT:-${REPO_ROOT}/out/linux-runtime}"
IMAGE_NAME="${IMAGE_NAME:-}"
ARCHITECTURES="${ARCHITECTURES:-amd64,arm64,riscv64}"

PUSH_IMAGES=0

TMP_DIRS=()

usage() {
  cat <<'EOF'
Usage: build-runtime-manifest.sh --image IMAGE [options]

Builds one runtime image per architecture from prebuilt rootfs artifacts and
optionally pushes a multi-architecture manifest with nerdctl.

Expected artifact layout:
  out/linux-runtime/amd64/rootfs/
  out/linux-runtime/arm64/rootfs/
  out/linux-runtime/riscv64/rootfs/

Options:
  --image IMAGE           Base image tag to use (required)
  --artifacts-root DIR    Root directory for per-architecture rootfs trees
  --architectures LIST    Comma-separated list (default: amd64,arm64,riscv64)
  --push                  Push per-architecture images and the manifest
  -h, --help              Show this help text

Environment overrides:
  NERDCTL_BIN             nerdctl executable to use
  ARTIFACTS_ROOT          Root directory for artifacts
  IMAGE_NAME              Base image name, equivalent to --image
  ARCHITECTURES           Comma-separated architecture list
EOF
}

log() {
  printf '[INFO] %s\n' "$*"
}

run() {
  printf '+ '
  printf '%q ' "$@"
  printf '\n'
  "$@"
}

cleanup() {
  local dir
  for dir in "${TMP_DIRS[@]}"; do
    rm -rf "${dir}"
  done
}
trap cleanup EXIT

stage_context() {
  local arch="$1"
  local src_rootfs="${ARTIFACTS_ROOT}/${arch}/rootfs"
  local ctx

  if [ ! -d "${src_rootfs}" ]; then
    printf '[ERROR] Missing artifact rootfs for %s: %s\n' "${arch}" "${src_rootfs}" >&2
    exit 1
  fi

  ctx="$(mktemp -d)"
  TMP_DIRS+=("${ctx}")

  mkdir -p "${ctx}/rootfs" "${ctx}/runtime"
  cp "${REPO_ROOT}/linux/Dockerfile.runtime-artifact" "${ctx}/Dockerfile"
  cp -a "${src_rootfs}/." "${ctx}/rootfs/"
  cp -a "${REPO_ROOT}/linux/scripts/04-runtime/." "${ctx}/runtime/"
  cp "${REPO_ROOT}/linux/scripts/02-toolchain/vulkan.sh" "${ctx}/runtime/vulkan.sh"
  chmod +x "${ctx}/runtime/"*.sh 2>/dev/null || true

  printf '%s' "${ctx}"
}

build_arch_image() {
  local arch="$1"
  local tag="${IMAGE_NAME}-${arch}"
  local ctx

  ctx="$(stage_context "${arch}")"

  run "${NERDCTL_BIN}" build \
    --platform "linux/${arch}" \
    -t "${tag}" \
    -f "${ctx}/Dockerfile" \
    "${ctx}"

  if [ "${PUSH_IMAGES}" -eq 1 ]; then
    run "${NERDCTL_BIN}" push "${tag}"
  fi
}

create_manifest() {
  local refs=()
  local arch

  for arch in ${ARCHITECTURES//,/ }; do
    refs+=("${IMAGE_NAME}-${arch}")
  done

  "${NERDCTL_BIN}" manifest rm "${IMAGE_NAME}" >/dev/null 2>&1 || true
  run "${NERDCTL_BIN}" manifest create "${IMAGE_NAME}" "${refs[@]}"

  if [ "${PUSH_IMAGES}" -eq 1 ]; then
    run "${NERDCTL_BIN}" manifest push --purge "${IMAGE_NAME}"
  fi
}

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --image)
        IMAGE_NAME="$2"
        shift 2
        ;;
      --artifacts-root)
        ARTIFACTS_ROOT="$2"
        shift 2
        ;;
      --architectures)
        ARCHITECTURES="$2"
        shift 2
        ;;
      --push)
        PUSH_IMAGES=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        printf '[ERROR] Unknown option: %s\n' "$1" >&2
        usage >&2
        exit 1
        ;;
    esac
  done

  if [ -z "${IMAGE_NAME}" ]; then
    printf '[ERROR] --image is required\n' >&2
    usage >&2
    exit 1
  fi

  cd "${REPO_ROOT}"

  local arch
  for arch in ${ARCHITECTURES//,/ }; do
    build_arch_image "${arch}"
  done

  create_manifest
}

main "$@"
