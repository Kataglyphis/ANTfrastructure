#!/usr/bin/env bash
# Host-owned workspaces and SDK hooks need the same setup in build and test launchers.
[ -n "${_PROJECT_ENV_LOADED:-}" ] && return 0
_PROJECT_ENV_LOADED=1
# shellcheck source=../01-core/vulkan-env.sh
source "$(dirname "${BASH_SOURCE[0]}")/../01-core/vulkan-env.sh"

project_env_allow_git_directory() {
  if [[ -n "$1" ]]; then
    git config --global --add safe.directory "$1" || true
  fi
}

project_env_source_vulkan() {
  if declare -F source_vulkan_env >/dev/null 2>&1; then
    source_vulkan_env
  elif [[ -n "${VULKAN_SETUP_SCRIPT:-}" && -f "${VULKAN_SETUP_SCRIPT}" ]]; then
    _vulkan_env_log "Sourcing Vulkan env from: ${VULKAN_SETUP_SCRIPT}"
    vulkan_env_source_script "${VULKAN_SETUP_SCRIPT}"
  fi
}
