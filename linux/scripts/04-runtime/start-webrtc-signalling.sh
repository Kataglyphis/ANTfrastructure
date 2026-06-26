#!/usr/bin/env bash
set -euo pipefail

# Start WebRTC signalling server in the background and keep container alive
# This script is used as the command in docker-compose

WEBRTC_HOST="${WEBRTC_HOST:-0.0.0.0}"
WEBRTC_PORT="${WEBRTC_PORT:-8443}"

echo "Starting WebRTC signalling server on ${WEBRTC_HOST}:${WEBRTC_PORT}..."
/opt/gstreamer/bin/gst-webrtc-signalling-server --host "${WEBRTC_HOST}" --port "${WEBRTC_PORT}" &
echo "WebRTC signalling server started (PID: $!)"

# Keep container running (wait forwards signals to child process)
wait
