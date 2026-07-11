#!/usr/bin/env bash
set -euo pipefail

# smoke-runtime-image.sh
# Validates that the runtime wrapper image starts correctly:
#   - Image can run a trivial command
#   - Entrypoint is functional
#   - HEALTHCHECK responds
#   - Kataglyphis user exists
#   - Key runtime paths exist
#   - Functional: onnxruntime/numpy/torch import + ffmpeg executes inside the
#     image (under qemu for cross arches); torch-less sentinel is flagged.
#     Skip with RUNTIME_FUNCTIONAL_SMOKE=0; accept torch-less with
#     ALLOW_TORCHLESS_RUNTIME=1.
#
# Usage:
#   smoke-runtime-image.sh <image-tag> [target-arch]
#   smoke-runtime-image.sh ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross-arm64 arm64

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_SCRIPT_DIR}/smoke-common.sh"

NERDCTL_BIN="${NERDCTL_BIN:-nerdctl}"

# Evaluate a python expression against the image's `nerdctl image inspect` JSON
# (the [0] element on stdin). Prints the expr's output, empty on any error.
# DRYs the repeated `nerdctl image inspect | python3 -c` boilerplate. Uses the
# caller's ${image_tag} via dynamic scope.
inspect_image_config() {
  "${NERDCTL_BIN}" image inspect "${image_tag}" 2>/dev/null | python3 -c "$1" 2>/dev/null || true
}

main() {
  local image_tag="${1:-}"
  local target_arch="${2:-}"

  if [ -z "${image_tag}" ]; then
    echo "Usage: $0 <image-tag> [target-arch]" >&2
    exit 1
  fi

  if [ -z "${target_arch}" ]; then
    target_arch="$(smoke_host_arch)"
  fi

  echo "=== Runtime Image Smoke Test ==="
  echo "Image: ${image_tag}"
  echo "Arch: ${target_arch}"
  echo ""

  # 1. Ensure image exists locally (pull if needed)
  echo "--- Image availability ---"
  if ! "${NERDCTL_BIN}" image inspect "${image_tag}" >/dev/null 2>&1; then
    echo "  Pulling ${image_tag}..."
    "${NERDCTL_BIN}" pull --platform "linux/${target_arch}" "${image_tag}" || {
      fail "Cannot pull image ${image_tag}"
      smoke_summary
    }
  fi
  pass "Image ${image_tag} available"
  echo ""

  # 2. Run a trivial command
  echo "--- Trivial command ---"
  if "${NERDCTL_BIN}" run --rm --platform "linux/${target_arch}" "${image_tag}" /bin/true 2>/dev/null; then
    pass "Container can run /bin/true"
  else
    fail "Container cannot run /bin/true"
  fi
  echo ""

  # 3. Check entrypoint
  echo "--- Entrypoint ---"
  local config
  config="$(inspect_image_config "import sys,json; print(json.load(sys.stdin)[0].get('Config',{}).get('Entrypoint',''))")"
  if [ -n "${config}" ]; then
    pass "Entrypoint configured: ${config}"
  else
    fail "No entrypoint configured"
  fi
  echo ""

  # 4. Check HEALTHCHECK
  echo "--- HEALTHCHECK ---"
  local healthcheck
  healthcheck="$(inspect_image_config "import sys,json; cfg=json.load(sys.stdin)[0].get('Config',{}); hc=cfg.get('Healthcheck',{}); print(hc.get('Test',[''])[0] if hc else 'NONE')")"
  if [ -n "${healthcheck}" ] && [ "${healthcheck}" != "NONE" ]; then
    pass "HEALTHCHECK configured: ${healthcheck}"
  else
    fail "No HEALTHCHECK configured"
  fi
  echo ""

  # 5. Check kataglyphis user exists
  echo "--- kataglyphis user ---"
  if "${NERDCTL_BIN}" run --rm --platform "linux/${target_arch}" "${image_tag}" id -u kataglyphis >/dev/null 2>&1; then
    pass "kataglyphis user exists"
  else
    fail "kataglyphis user not found"
  fi
  echo ""

  # 6. Check WORKDIR
  echo "--- WORKDIR ---"
  local workdir
  workdir="$(inspect_image_config "import sys,json; print(json.load(sys.stdin)[0].get('Config',{}).get('WorkingDir',''))")"
  if [ -n "${workdir}" ]; then
    pass "WORKDIR: ${workdir}"
  else
    echo "  INFO: No WORKDIR set"
  fi
  echo ""

  # 7. Check VOLUME
  echo "--- VOLUME ---"
  local volumes
  volumes="$(inspect_image_config "import sys,json; vols=json.load(sys.stdin)[0].get('Config',{}).get('Volumes',''); print(':'.join(vols.keys()) if vols and isinstance(vols,dict) else 'NONE')")"
  if [ -n "${volumes}" ] && [ "${volumes}" != "NONE" ]; then
    pass "VOLUME: ${volumes}"
  else
    echo "  INFO: No VOLUME set"
  fi
  echo ""

  # 8. Check OCI labels
  echo "--- OCI labels ---"
  local labels
  labels="$(inspect_image_config "import sys,json; lbs=json.load(sys.stdin)[0].get('Config',{}).get('Labels',{}); [print(f'{k}={v}') for k,v in sorted(lbs.items())]")"
  if [ -n "${labels}" ]; then
    local label_count
    label_count="$(echo "${labels}" | wc -l)"
    pass "${label_count} OCI label(s) configured"
  else
    fail "No OCI labels configured"
  fi
  echo ""

  # 9. Functional checks (D1/D2): actually LOAD the compiled ML stack and RUN
  #    ffmpeg INSIDE the image -- under binfmt/qemu for cross arches. The checks
  #    above prove the image boots and its metadata is sane; these prove the
  #    arch-specific NATIVE extensions genuinely import/execute on the target
  #    (previously only validated on native amd64 or on real hardware). Runs
  #    through the entrypoint so the gstreamer/libcamera/vulkan env matches
  #    runtime. Gate RUNTIME_FUNCTIONAL_SMOKE=0 to skip (e.g. no qemu handler).
  if [ "${RUNTIME_FUNCTIONAL_SMOKE:-1}" = "1" ]; then
    echo "--- Functional: torch-less sentinel (A3) ---"
    local torch_expected=1
    if "${NERDCTL_BIN}" run --rm --platform "linux/${target_arch}" "${image_tag}" \
         test -f /opt/venv/.torch-missing >/dev/null 2>&1; then
      torch_expected=0
      if [ "${ALLOW_TORCHLESS_RUNTIME:-0}" = "1" ]; then
        echo "  INFO: /opt/venv/.torch-missing present -- image ships WITHOUT torch (allowed)"
      else
        fail "Image ships WITHOUT torch (/opt/venv/.torch-missing present); set ALLOW_TORCHLESS_RUNTIME=1 to accept"
      fi
    else
      pass "No torch-less sentinel (torch expected in image)"
    fi
    echo ""

    echo "--- Functional: ML imports ---"
    if "${NERDCTL_BIN}" run --rm --platform "linux/${target_arch}" "${image_tag}" \
         /opt/venv/bin/python -c "import onnxruntime, numpy; print('onnxruntime', onnxruntime.__version__, '| numpy', numpy.__version__)"; then
      pass "onnxruntime + numpy import OK (${target_arch})"
    else
      fail "onnxruntime/numpy failed to import in the runtime image (${target_arch})"
    fi
    if [ "${torch_expected}" = "1" ]; then
      if "${NERDCTL_BIN}" run --rm --platform "linux/${target_arch}" "${image_tag}" \
           /opt/venv/bin/python -c "import torch; print('torch', torch.__version__)"; then
        pass "torch import OK (${target_arch})"
      else
        fail "torch failed to import in the runtime image (${target_arch})"
      fi
    else
      echo "  INFO: skipping torch import (torch-less image)"
    fi
    # cv2 needs the source-built OpenCV5 bindings + GL/EGL runtime libs; report
    # informationally so a missing optional binding does not fail the gate.
    if "${NERDCTL_BIN}" run --rm --platform "linux/${target_arch}" "${image_tag}" \
         /opt/venv/bin/python -c "import cv2; print('cv2', cv2.__version__)" 2>/dev/null; then
      pass "cv2 import OK (${target_arch})"
    else
      echo "  INFO: cv2 did not import (optional; verify /opt/opencv5 bindings on ${target_arch})"
    fi
    echo ""

    echo "--- Functional: ffmpeg ---"
    # pipefail is REQUIRED: without it, `ffmpeg -version | head -1` returns head's
    # exit (0), so a broken binary -- e.g. `error while loading shared libraries:
    # libopencore-amrwb.so.0` (observed 2026-07-11) -- silently PASSES. With
    # pipefail the missing-.so exit code propagates and the smoke fails as it must.
    if "${NERDCTL_BIN}" run --rm --platform "linux/${target_arch}" "${image_tag}" \
         bash -lc 'set -o pipefail; v="$(command -v ffmpeg || echo /opt/ffmpeg/bin/ffmpeg)"; "$v" -version | head -1'; then
      pass "ffmpeg executes (${target_arch})"
    else
      fail "ffmpeg failed to execute in the runtime image (${target_arch})"
    fi
    echo ""
  else
    echo "--- Functional checks skipped (RUNTIME_FUNCTIONAL_SMOKE=0) ---"
    echo ""
  fi

  smoke_summary
}

main "$@"
