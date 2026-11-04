#!/usr/bin/env bash
# Stages the three Tegra libraries DeepStream's arm64 route needs out of NVIDIA's SBSA container: docs/linux-accelerator-images.md#deepstream-on-arm64-sbsa
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/../../.." && pwd)"
# shellcheck source=../01-core/load-versions-env.sh
source "${HERE}/../01-core/load-versions-env.sh"
load_versions_env "${HERE}/../01-core/versions.env"
# shellcheck source=deepstream.sh
source "${HERE}/deepstream.sh"

# DEEPSTREAM_SBSA_DIR is the drop point the chain reads too (build-helpers.sh); --check verifies without the container.
DEST="${DEEPSTREAM_SBSA_DIR:-${REPO_ROOT}/linux/deepstream-sbsa}"
NERDCTL="${NERDCTL:-nerdctl}"
case "${1:-}" in
  "") MODE=stage ;;
  --check) MODE=check ;;
  *) echo "usage: [DEEPSTREAM_SBSA_DIR=DIR] stage-deepstream-sbsa.sh [--check]" >&2; exit 2 ;;
esac

# The container's layout: the tree links the three into the Tegra dir; cp -L takes the bytes.
DS_TREE="/opt/nvidia/deepstream/deepstream-${DEEPSTREAM_VERSION%.*}"

sbsa_verify() {
  local problem
  problem="$(DS_SBSA_DIR="${DEST}" ds_sbsa_problem)"
  if [ -n "${problem}" ]; then
    printf '%s\n' "${problem}" >&2
    return 1
  fi
  echo "deepstream-sbsa: ${DEST} holds the three pinned libraries from ${DEEPSTREAM_SBSA_IMAGE}"
}

# nerdctl run with the host dir mounted; a kernel that refuses the default AppArmor profile gets one retry unconfined, said out loud.
sbsa_run() {
  "${NERDCTL}" run --rm --platform linux/arm64 -v "${DEST}:/stage" --entrypoint /bin/bash "${DEEPSTREAM_SBSA_IMAGE}" -c "$1" && return 0
  echo "deepstream-sbsa: retrying with --security-opt apparmor=unconfined (the default profile failed to apply)" >&2
  "${NERDCTL}" run --rm --platform linux/arm64 --security-opt apparmor=unconfined -v "${DEST}:/stage" --entrypoint /bin/bash "${DEEPSTREAM_SBSA_IMAGE}" -c "$1"
}

sbsa_stage() {
  local f key files=""
  command -v "${NERDCTL}" >/dev/null || { echo "deepstream-sbsa: ${NERDCTL} is not on PATH" >&2; return 1; }
  mkdir -p "${DEST}"
  while read -r f key; do files+=" ${DS_TREE}/lib/${f%.1.0.0}"; done < <(ds_sbsa_libs)
  "${NERDCTL}" pull --platform linux/arm64 "${DEEPSTREAM_SBSA_IMAGE}" >/dev/null
  # The versioned names are what the tree links and the plugins need; the licence rides along as the container ships it.
  sbsa_run "set -e; for s in ${files}; do cp -L \"\$(readlink -f \"\$s\")\" /stage/; done; cp ${DS_TREE}/LicenseAgreement.pdf /stage/; \
    printf 'image=%s\ndate=%s\nsource=%s\n' '${DEEPSTREAM_SBSA_IMAGE}' \"\$(date -u +%Y-%m-%dT%H:%M:%SZ)\" \"\$(readlink -f ${DS_TREE}/lib/libnvbufsurface.so | xargs dirname)\" > /stage/PROVENANCE.txt"
  sbsa_verify
}

case "${MODE}" in
  check) sbsa_verify ;;
  stage) sbsa_stage ;;
esac
