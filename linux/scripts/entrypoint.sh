#!/usr/bin/env bash
set -euo pipefail

# entrypoint.sh — source env scripts (so they export into this shell) and exec the CMD.
# Usage (Dockerfile):
#   ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
#   CMD ["/bin/bash"]
#
# At runtime, set VULKAN_VERSION in the environment (e.g. via Dockerfile: ENV VULKAN_VERSION=1.3.258)
# If VULKAN_VERSION is not set, the script will try to source the first matching /opt/vulkan/*/setup-env.sh.

# --- helper: safe source if file exists ---
_safe_source() {
  local f="$1"
  if [ -f "$f" ]; then
    # shellcheck disable=SC1090
    source "$f"
    return 0
  fi
  return 1
}

# Source standard env scripts (these must be sourced to export variables into this shell)
_safe_source /usr/local/bin/gstreamer-env.sh || \
  echo "Warning: /usr/local/bin/gstreamer-env.sh not found or not sourced" >&2
_safe_source /usr/local/bin/libcamera-env.sh || \
  echo "Warning: /usr/local/bin/libcamera-env.sh not found or not sourced" >&2

# Source Vulkan env: prefer VULKAN_VERSION if set, otherwise pick first available /opt/vulkan/*/setup-env.sh
VULKAN_PREFIX="${VULKAN_PREFIX:-/opt/vulkan}"

if [ -n "${VULKAN_VERSION:-}" ]; then
  VULKAN_SETUP="${VULKAN_PREFIX}/${VULKAN_VERSION}/setup-env.sh"
  if _safe_source "$VULKAN_SETUP"; then
    :
  else
    echo "Warning: Vulkan setup ${VULKAN_SETUP} not found; falling back to any /opt/vulkan/*/setup-env.sh" >&2
    # fall through to fallback logic below
    unset VULKAN_SETUP
  fi
fi

# Fallback: if we didn't source a specific version, try to source the first setup-env.sh found under prefix
if [ -z "${VULKAN_SETUP:-}" ]; then
  found=false
  for d in "${VULKAN_PREFIX}"/*; do
    [ -d "$d" ] || continue
    if _safe_source "${d}/setup-env.sh"; then
      found=true
      break
    fi
  done
  if [ "$found" = false ]; then
    echo "Warning: no Vulkan setup-env.sh found under ${VULKAN_PREFIX}" >&2
  fi
fi

# Optional: run a one-shot setup script (execute, not source) if present
if [ -x /usr/local/bin/one-time-setup.sh ]; then
  echo "Running one-time setup..."
  /usr/local/bin/one-time-setup.sh "$@" || {
    echo "one-time-setup.sh failed" >&2
    exit 1
  }
fi

# If no command provided, default to /bin/bash
if [ $# -eq 0 ]; then
  set -- /bin/bash
fi

# Replace this script with the target command so it runs as PID 1 (proper signal handling)
exec "$@"
