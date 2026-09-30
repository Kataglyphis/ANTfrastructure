#!/usr/bin/env bash
# Cross-chain and runtime tag names; source directly or through artifact-common.sh.
[ -n "${_TAG_NAMING_SH_LOADED:-}" ] && return 0
_TAG_NAMING_SH_LOADED=1

# Cross-chain tags are :cross-<stage>-<arch>, except the shared stages, which carry the build host arch.

# From its GPU layer on, a variant tags with -<variant> and so never overwrites :latest; ENABLE_NVIDIA/AMD imply it.
cross_variant() {
  local v="${CROSS_VARIANT:-}"
  if [ -z "${v}" ]; then
    if [ "${ENABLE_NVIDIA:-false}" = "true" ] && [ "${ENABLE_AMD:-false}" = "true" ]; then
      printf '[ERROR] ENABLE_NVIDIA and ENABLE_AMD are both true; one chain builds one variant\n' >&2
      return 1
    fi
    [ "${ENABLE_NVIDIA:-false}" = "true" ] && v=nvidia
    [ "${ENABLE_AMD:-false}" = "true" ] && v=rocm
  fi
  case "${v}" in
    ''|nvidia|rocm) printf '%s' "${v}" ;;
    *) printf '[ERROR] unknown CROSS_VARIANT %s (nvidia|rocm, or unset for :latest)\n' "${v}" >&2
       return 1 ;;
  esac
}
cross_variant_infix() {
  local v; v="$(cross_variant)" || return 1
  [ -z "${v}" ] || printf -- '-%s' "${v}"
}

# Shared stages carry the build host arch, or a non-amd64 host's FROM silently resolves the registry's amd64 image.
_cross_build_host_arch()      { build_arch_oci 2>/dev/null || printf '%s' amd64; }
_cross_shared_tag_suffix() {
  local a; a="$(_cross_build_host_arch)"
  [ "${a}" = "amd64" ] && return 0
  printf -- '-%s' "${a}"
}
cross_base_tag()              { printf '%s' "${IMAGE_REPO:-${IMAGE_REGISTRY_PREFIX}}:base$(_cross_shared_tag_suffix)"; }
cross_compiler_tag()          { printf '%s' "${IMAGE_REPO:-${IMAGE_REGISTRY_PREFIX}}:cross-compiler-$(_cross_build_host_arch)"; }
cross_sdk_tag()               { printf '%s' "${IMAGE_REPO:-${IMAGE_REGISTRY_PREFIX}}:cross-sdk-${1}"; }
cross_media_tag()             { printf '%s' "${IMAGE_REPO:-${IMAGE_REGISTRY_PREFIX}}:cross-media$(cross_variant_infix)-${1}"; }
# The variant chain's GPU library layer between sdk and media.
cross_gpu_tag()               { printf '%s' "${IMAGE_REPO:-${IMAGE_REGISTRY_PREFIX}}:cross-toolchain$(cross_variant_infix)-${1}"; }
# Android lacks the NDK off amd64, so a non-amd64 host tags -host<arch> rather than overwrite the amd64 artifact.
cross_build_host_infix() {
  local a; a="$(_cross_build_host_arch)"
  [ "${a}" = "amd64" ] && return 0
  printf -- '-host%s' "${a}"
}
# One function for cross-stage-build.sh's --artifact-image-prefix and cross_android_tag, so they cannot drift.
cross_android_tag_prefix()    { printf '%s' "${IMAGE_REPO:-${IMAGE_REGISTRY_PREFIX}}:cross-android$(cross_variant_infix)$(cross_build_host_infix)"; }
cross_android_tag()           { printf '%s' "$(cross_android_tag_prefix)-${1}"; }
# Same host infix, as wrappers push before the manifest gate; never the shared suffix, whose :latest-arm64 is taken.
cross_final_image_tag()       { printf '%s' "${IMAGE_REPO:-${IMAGE_REGISTRY_PREFIX}}:latest$(cross_variant_infix)$(cross_build_host_infix)"; }

# Runtime tags
runtime_require_image_prefix() {
  if [ -z "${RUNTIME_IMAGE_PREFIX:-}" ]; then
    printf '[ERROR] RUNTIME_IMAGE_PREFIX is required\n' >&2
    return 1
  fi
}

runtime_base_tag() {
  local arch="$1"
  runtime_require_image_prefix || return 1
  printf '%s' "${RUNTIME_IMAGE_PREFIX}-base-${arch}"
}

runtime_package_tag() {
  local arch="$1"
  runtime_require_image_prefix || return 1
  printf '%s' "${RUNTIME_IMAGE_PREFIX}-package-${arch}"
}

runtime_wrapper_tag() {
  local arch="$1"
  runtime_require_image_prefix || return 1
  printf '%s' "${RUNTIME_IMAGE_PREFIX}-${arch}"
}

runtime_artifact_platform() {
  local arch="$1"
  case "${ARTIFACT_BUILD_MODE:-cross}" in
    cross)
      # The platform the cross lane built on, never a literal amd64.
      local p; p="$(cross_build_platform)"
      if [ -z "${p}" ]; then
        printf '[ERROR] cross_build_platform returned empty (platform.sh not loaded?)\n' >&2
        return 1
      fi
      printf '%s' "${p}" ;;
    native) printf '%s' "linux/${arch}" ;;
    *)
      printf '[ERROR] Unsupported artifact build mode: %s\n' "${ARTIFACT_BUILD_MODE}" >&2
      return 1
      ;;
  esac
}

# Env name of <arch>'s android digest pin; exporter and reader both derive it here so they cannot drift.
runtime_android_pin_varname() {
  local arch="$1"
  printf 'RUNTIME_ANDROID_PIN_%s' "${arch//[^A-Za-z0-9_]/_}"
}

runtime_artifact_image_ref() {
  local arch="$1"
  case "${ARTIFACT_BUILD_MODE:-cross}" in
    cross) printf '%s' "${ARTIFACT_IMAGE_PREFIX}-${arch}" ;;
    native) printf '%s' "${ARTIFACT_IMAGE_PREFIX}" ;;
    *)
      printf '[ERROR] Unsupported artifact build mode: %s\n' "${ARTIFACT_BUILD_MODE}" >&2
      return 1
      ;;
  esac
}
