#!/usr/bin/env bash
# tag-naming.sh — centralized cross-chain and runtime tag name functions.
# Source this directly or through artifact-common.sh.
[ -n "${_TAG_NAMING_SH_LOADED:-}" ] && return 0
_TAG_NAMING_SH_LOADED=1
#
# Provides:
#   cross_base_tag()              — :base
#   cross_compiler_tag()          — :cross-compiler-amd64
#   cross_sdk_tag()               — :cross-sdk-<arch>
#   cross_media_tag()             — :cross-media-<arch>
#   cross_android_tag()           — :cross-android-<arch>
#   runtime_base_tag()            — <prefix>-base-<arch>
#   runtime_package_tag()         — <prefix>-package-<arch>
#   runtime_wrapper_tag()         — <prefix>-<arch>
#   runtime_artifact_image_ref()  — cross-android ref or native artifact
#   runtime_artifact_platform()   — linux/amd64 or linux/<arch>
#   runtime_require_image_prefix()— guard for RUNTIME_IMAGE_PREFIX

# ==============================================================================
# Cross-chain tag name functions.
# Standard pattern: :cross-<stage>-<arch>
# Exception: :base has no cross-arch suffix (shared infrastructure).
# ==============================================================================
cross_base_tag()              { printf '%s' "${IMAGE_REPO:-${IMAGE_REGISTRY_PREFIX}}:base"; }
cross_compiler_tag()          { printf '%s' "${IMAGE_REPO:-${IMAGE_REGISTRY_PREFIX}}:cross-compiler-amd64"; }
cross_sdk_tag()               { printf '%s' "${IMAGE_REPO:-${IMAGE_REGISTRY_PREFIX}}:cross-sdk-${1}"; }
cross_media_tag()             { printf '%s' "${IMAGE_REPO:-${IMAGE_REGISTRY_PREFIX}}:cross-media-${1}"; }
cross_android_tag()           { printf '%s' "${IMAGE_REPO:-${IMAGE_REGISTRY_PREFIX}}:cross-android-${1}"; }

# ==============================================================================
# Runtime tag name functions.
# ==============================================================================
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
    cross) printf '%s' "linux/amd64" ;;
    native) printf '%s' "linux/${arch}" ;;
    *)
      printf '[ERROR] Unsupported artifact build mode: %s\n' "${ARTIFACT_BUILD_MODE}" >&2
      return 1
      ;;
  esac
}

# Environment variable name carrying the immutable android artifact digest for
# <arch> (XC2). The cross orchestrator exports it from the captured ANDROID_PIN
# so the runtime helper packages from — and records provenance against — the
# exact android generation this run produced, not the mutable cross-android tag.
# Both the exporter (cross-stage-build.sh) and the reader (runtime-build-fns.sh)
# derive the name here so they can never drift; arch is sanitized to a legal
# shell identifier.
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
