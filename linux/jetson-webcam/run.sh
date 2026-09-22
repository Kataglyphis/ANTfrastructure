#!/usr/bin/env bash
# Webcam object detection on a Jetson GPU, in the arm64 GPU wrapper image.
# The three GPU flags and why each is needed: docs/linux-host-setup.md § B2b.
set -euo pipefail

IMAGE="${JETSON_WEBCAM_IMAGE:-ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-hostarm64-arm64}"
CAMERA="${JETSON_WEBCAM_CAMERA:-/dev/video0}"
PORT="${JETSON_WEBCAM_PORT:-8080}"
CDI_DIR="${HOME}/.config/cdi"
CRUN="${HOME}/.local/bin/crun"
CACHE="${HOME}/.cache/jetson-webcam"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { printf 'jetson-webcam: %s\n' "$*" >&2; exit 1; }

[ -e "${CAMERA}" ] || die "no camera at ${CAMERA} (set JETSON_WEBCAM_CAMERA)"
[ -x "${CRUN}" ] || die "${CRUN} missing -- install crun >= 1.2x there (docs/linux-host-setup.md § B2b)"
if [ ! -f "${CDI_DIR}/nvidia.yaml" ]; then
  [ -f /var/run/cdi/nvidia.yaml ] || die "no CDI spec -- is nvidia-container-toolkit installed?"
  mkdir -p "${CDI_DIR}" && cp /var/run/cdi/nvidia.yaml "${CDI_DIR}/"
fi
mkdir -p "${CACHE}"
tty=(); [ -t 0 ] && tty=(-it)

# --user 0 is the invoking host user under rootless, and owns the weight cache.
exec nerdctl --cdi-spec-dirs "${CDI_DIR}" run --rm ${tty[@]+"${tty[@]}"} --name jetson-webcam \
  --runtime "${CRUN}" --annotation run.oci.keep_original_groups=1 \
  --device nvidia.com/gpu=all --device "${CAMERA}" \
  --user 0 -e TORCH_HOME=/cache -v "${CACHE}:/cache" \
  -v "${HERE}:/app:ro" -p "${PORT}:${PORT}" \
  "${IMAGE}" python /app/app.py --camera "${CAMERA}" --port "${PORT}" "$@"
