#!/usr/bin/env bash
set -euo pipefail

# docker-compose command: runs the WebRTC signalling server and keeps the container alive.

WEBRTC_HOST="${WEBRTC_HOST:-0.0.0.0}"
WEBRTC_PORT="${WEBRTC_PORT:-8443}"

echo "Starting WebRTC signalling server on ${WEBRTC_HOST}:${WEBRTC_PORT}..."
/opt/gstreamer/bin/gst-webrtc-signalling-server --host "${WEBRTC_HOST}" --port "${WEBRTC_PORT}" &
child_pid=$!
echo "WebRTC signalling server started (PID: ${child_pid})"

# `wait` forwards no signals; the flag re-waits only after the trap, so a child's own 128+N status survives.
signalled=0
trap 'signalled=1; kill -TERM "${child_pid}" 2>/dev/null' TERM INT

# A trapped `wait` returns before the child exits, so wait again for its real status.
status=0
wait "${child_pid}" || status=$?
if [ "${signalled}" -eq 1 ]; then
  status=0
  wait "${child_pid}" || status=$?
fi
exit "${status}"
