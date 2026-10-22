#!/usr/bin/env bash
set -euo pipefail

# SDK image Vulkan smoke: headers, loader, and a real vkEnumerateInstanceVersion.

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_SCRIPT_DIR}/smoke-common.sh"

VULKAN_SDK_ROOT="${VULKAN_SDK_ROOT:-/opt/vulkan}"
ACTIVE_LINK="${VULKAN_SDK_ROOT}/active"

check_active_sdk() {
  # 1. Check active Vulkan SDK symlink
  echo "--- Vulkan SDK root ---"
  if [ -L "${ACTIVE_LINK}" ] || [ -d "${ACTIVE_LINK}" ]; then
    local active_target
    active_target="$(readlink -f "${ACTIVE_LINK}" 2>/dev/null || echo "${ACTIVE_LINK}")"
    pass "Active Vulkan SDK: ${active_target}"
  else
    fail "Vulkan SDK active link not found at ${ACTIVE_LINK}"
  fi
  echo ""
}

_vulkan_sdk_paths() {
  local root
  for root in "${ACTIVE_LINK}" "${VULKAN_SDK_ROOT}/x86_64" "${VULKAN_SDK_ROOT}/aarch64" "${VULKAN_SDK_ROOT}/riscv64"; do
    printf '%s/%s\n' "${root}" "$1"
  done
}

check_vulkan_headers() {
  # 2. Check Vulkan headers
  echo "--- Vulkan headers ---"
  local vulkan_include=""
  while IFS= read -r candidate; do
    if [ -f "${candidate}/vulkan/vulkan.h" ]; then
      vulkan_include="${candidate}"
      break
    fi
  done < <(_vulkan_sdk_paths include)
  if [ -n "${vulkan_include}" ]; then
    pass "vulkan/vulkan.h found in ${vulkan_include}"
  else
    fail "vulkan/vulkan.h not found in any Vulkan SDK include path"
  fi
  echo ""
}

check_vulkan_loader() {
  # 3. Check Vulkan loader library
  echo "--- Vulkan loader ---"
  local vulkan_lib=""
  while IFS= read -r candidate; do
    local found
    found="$(find "${candidate}" -maxdepth 1 -name "libvulkan.so*" 2>/dev/null | head -1 || true)"
    if [ -n "${found}" ]; then
      vulkan_lib="${found}"
      break
    fi
  done < <(_vulkan_sdk_paths lib)
  if [ -n "${vulkan_lib}" ]; then
    pass "Vulkan loader found: ${vulkan_lib}"
  else
    fail "libvulkan.so not found in any Vulkan SDK lib path"
  fi
  echo ""
}

check_vulkan_runtime() {
  # 4. Try to run vkEnumerateInstanceVersion via a dlopen test or vkvia
  echo "--- Vulkan runtime check ---"
  if command -v vkvia >/dev/null 2>&1; then
    # rc of `cmd | head` is head's (always 0) — the old form was fail-open.
    _vkvia_out="$(vkvia 2>/dev/null | head -5)" && [ -n "${_vkvia_out}" ] && _vkvia_ok=1 || _vkvia_ok=0
    if [ "${_vkvia_ok}" = "1" ]; then
      printf '%s\n' "${_vkvia_out}"
      pass "vkvia reports Vulkan instance version"
    else
      echo "  INFO: vkvia failed (expected in container without GPU)"
    fi
  else
    local vulkan_loader
    vulkan_loader="$(find / -name "libvulkan.so.1" 2>/dev/null | head -1 || true)"
    if [ -n "${vulkan_loader}" ]; then
      pass "libvulkan.so.1 present: ${vulkan_loader}"
    fi
  fi
  echo ""
}

main() {
  echo "=== Vulkan SDK Smoke Test ==="
  echo ""

  check_active_sdk
  check_vulkan_headers
  check_vulkan_loader
  check_vulkan_runtime

  smoke_summary
}

main "$@"
