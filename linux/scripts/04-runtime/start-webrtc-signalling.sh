#!/usr/bin/env bash
set -euo pipefail

# Start WebRTC signalling server in the background and keep container alive
# This script is used as the command in docker-compose

WEBRTC_HOST="${WEBRTC_HOST:-0.0.0.0}"
WEBRTC_PORT="${WEBRTC_PORT:-8443}"

echo "Starting WebRTC signalling server on ${WEBRTC_HOST}:${WEBRTC_PORT}..."
/opt/gstreamer/bin/gst-webrtc-signalling-server --host "${WEBRTC_HOST}" --port "${WEBRTC_PORT}" &
child_pid=$!
echo "WebRTC signalling server started (PID: ${child_pid})"

# Forward container stop signals to the child so it can shut down cleanly
# (bare `wait` does NOT forward signals — without the trap, docker stop would
# leave the server to be SIGKILLed after the grace period).
trap 'kill -TERM "${child_pid}" 2>/dev/null' TERM INT

# Keep container running. If wait is interrupted by a trapped signal it
# returns 128+signum before the child has exited; wait again to reap the
# child and propagate its real exit code.
status=0
wait "${child_pid}" || status=$?
if [ "${status}" -gt 128 ]; then
  status=0
  wait "${child_pid}" || status=$?
fi
exit "${status}"
