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
# leave the server to be SIGKILLed after the grace period). The trap records
# that IT fired so we only re-wait in that case; a child that dies on its own
# by a signal (e.g. OOM-kill → 137) must keep its real 128+N status, not be
# re-waited into bash's "not a child" 127.
signalled=0
trap 'signalled=1; kill -TERM "${child_pid}" 2>/dev/null' TERM INT

# Keep container running. When our trap interrupts `wait` it returns 128+signum
# before the child has exited, so wait again to reap it and propagate its real
# exit code. When the child died on its own, propagate the first status as-is.
status=0
wait "${child_pid}" || status=$?
if [ "${signalled}" -eq 1 ]; then
  status=0
  wait "${child_pid}" || status=$?
fi
exit "${status}"
