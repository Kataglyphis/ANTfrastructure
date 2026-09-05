#!/usr/bin/env bash
set -euo pipefail

# prune-vulkan-host-sdk.sh — drop the LunarG SDK's builder-arch prefix (and any
# leftover build tree) from a Vulkan install root, keeping the prefix this image
# actually runs. Runs in Dockerfile.package's artifact-source stage, AHEAD of the
# /opt/vulkan COPY, so the runtime layer never carries what it cannot execute.
# docs/artifact-copy-completeness.md#the-vulkan-tree-ships-only-what-the-image-runs

HOST_PREFIX="x86_64"

_prune_load_platform() {
  local dir candidate
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  for candidate in \
    "${dir}/platform.sh" \
    "${dir}/../01-core/platform.sh" \
    /opt/scripts/core/platform.sh; do
    [ -r "${candidate}" ] || continue
    # shellcheck disable=SC1090
    source "${candidate}"
    declare -F arch_uname_name_for >/dev/null 2>&1 \
      && declare -F arch_deb_multiarch_triplet_for >/dev/null 2>&1 \
      && return 0
  done
  return 1
}

# The builder-arch prefix goes only when a REAL own-arch prefix carries the loader
# the image will load; on amd64 the two are the same directory and nothing goes.
vulkan_host_prefix_prunable() {
  local version_dir="$1" arch_dir="$2"

  [ "${arch_dir}" != "${HOST_PREFIX}" ] || return 1
  [ -d "${version_dir}/${HOST_PREFIX}" ] && [ ! -L "${version_dir}/${HOST_PREFIX}" ] || return 1
  [ -d "${version_dir}/${arch_dir}" ] && [ ! -L "${version_dir}/${arch_dir}" ] || return 1
  [ -e "${version_dir}/${arch_dir}/lib/libvulkan.so.1" ] || return 1
  return 0
}

_prune_version_dir() {
  local version_dir="$1" arch_dir="$2" target_arch="$3"

  if [ -d "${version_dir}/source" ]; then
    echo "vulkan-prune: removing ${version_dir}/source (SDK build tree, no consumer past the SDK stage)"
    rm -rf "${version_dir:?}/source"
  fi
  if vulkan_host_prefix_prunable "${version_dir}" "${arch_dir}"; then
    echo "vulkan-prune: removing ${version_dir}/${HOST_PREFIX} (builder-arch SDK; ${target_arch} runs ${arch_dir}/lib/libvulkan.so.1)"
    rm -rf "${version_dir:?}/${HOST_PREFIX}"
  elif [ "${arch_dir}" = "${HOST_PREFIX}" ]; then
    echo "vulkan-prune: keeping ${version_dir}/${HOST_PREFIX} (it is the prefix ${target_arch} runs)"
  else
    echo "vulkan-prune: WARNING keeping ${version_dir}/${HOST_PREFIX} — ${version_dir}/${arch_dir}/lib/libvulkan.so.1 is missing, so the cross Vulkan build did not land for ${target_arch}" >&2
  fi
}

main() {
  local target_arch="${1:-${TARGET_ARCH:-${TARGETARCH:-amd64}}}"
  local root="${2:-/opt/vulkan}"
  local arch_dir version_dir

  _prune_load_platform || {
    echo "ERROR: prune-vulkan-host-sdk.sh found no platform.sh defining arch_uname_name_for" >&2
    exit 1
  }
  arch_deb_multiarch_triplet_for "${target_arch}" >/dev/null 2>&1 || {
    echo "ERROR: no Vulkan SDK prefix name for target arch '${target_arch}'" >&2
    exit 1
  }
  arch_dir="$(arch_uname_name_for "${target_arch}")"

  if [ ! -d "${root}" ]; then
    echo "vulkan-prune: ${root} absent; nothing to prune"
    return 0
  fi
  for version_dir in "${root}"/*/; do
    version_dir="${version_dir%/}"
    [ -d "${version_dir}" ] && [ ! -L "${version_dir}" ] || continue
    _prune_version_dir "${version_dir}" "${arch_dir}" "${target_arch}"
  done
}

main "$@"
