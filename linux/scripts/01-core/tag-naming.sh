#!/usr/bin/env bash
# tag-naming.sh — centralized cross-chain and runtime tag name functions.
# Source this directly or through artifact-common.sh.
[ -n "${_TAG_NAMING_SH_LOADED:-}" ] && return 0
_TAG_NAMING_SH_LOADED=1
#
# Provides:
#   cross_base_tag()              — :base (+ -<arch> off an amd64 build host)
#   cross_compiler_tag()          — :cross-compiler-<build host arch>
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
# Exception: the two SHARED stages carry the BUILD HOST arch, not a target arch.
# ==============================================================================

# The two SHARED stages carry the BUILD HOST arch — that is what the "amd64" in
# :cross-compiler-amd64 always meant, merely frozen as a literal. On a non-amd64
# host the local artifact then collided with the registry's amd64 one under a
# single tag, and `FROM` took the REGISTRY's: a native arm64 sdk build silently
# ran on the amd64 compiler image (2026-09-10). An amd64 host keeps both
# historical names byte-for-byte.
_cross_build_host_arch()      { build_arch_oci 2>/dev/null || printf '%s' amd64; }
_cross_shared_tag_suffix() {
  local a; a="$(_cross_build_host_arch)"
  [ "${a}" = "amd64" ] && return 0
  printf -- '-%s' "${a}"
}
cross_base_tag()              { printf '%s' "${IMAGE_REPO:-${IMAGE_REGISTRY_PREFIX}}:base$(_cross_shared_tag_suffix)"; }
cross_compiler_tag()          { printf '%s' "${IMAGE_REPO:-${IMAGE_REGISTRY_PREFIX}}:cross-compiler-$(_cross_build_host_arch)"; }
cross_sdk_tag()               { printf '%s' "${IMAGE_REPO:-${IMAGE_REGISTRY_PREFIX}}:cross-sdk-${1}"; }
cross_media_tag()             { printf '%s' "${IMAGE_REPO:-${IMAGE_REGISTRY_PREFIX}}:cross-media-${1}"; }
# Android is the one per-arch stage whose IMAGE depends on the build host: on a
# non-amd64 host the NDK payload is absent (platform.sh:354), and every cross
# stage is ALWAYS pushed (build-cross-chain.sh:207). Without this infix a native
# arm64 run would overwrite the amd64 lane's real artifact under the same tag.
# Derived from _cross_build_host_arch so there is no fourth independent
# `= amd64` test; empty on amd64, so the historical name is byte-identical.
_cross_build_host_infix() {
  local a; a="$(_cross_build_host_arch)"
  [ "${a}" = "amd64" ] && return 0
  printf -- '-host%s' "${a}"
}
# Split so cross-stage-build.sh's --artifact-image-prefix and cross_android_tag
# are two callers of ONE function instead of two spellings that can drift.
cross_android_tag_prefix()    { printf '%s' "${IMAGE_REPO:-${IMAGE_REGISTRY_PREFIX}}:cross-android$(_cross_build_host_infix)"; }
cross_android_tag()           { printf '%s' "$(cross_android_tag_prefix)-${1}"; }

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
