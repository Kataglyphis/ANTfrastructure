#!/usr/bin/env bash
# ci-image-ref.sh - print the family CI container image reference.

# For callers that use no action; see docs/shared-script-libraries.md#ci-image-refsh--the-family-ci-image-reference

# No consumer root on purpose: it only ever reads this repo's versions.env.

# A missing key fails hard: an empty ref makes docker run treat the next argument as the image.
set -euo pipefail

# Overridable for the self-test only; the default is this repo's own copy.
: "${CI_IMAGE_REF_VERSIONS_ENV:=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/01-core/versions.env}"

# Parsed, never sourced: load_versions_env lets a stray env var win and redirect every caller.
ci_image_ref_read_key() {
  local key="${1:?key required}" file="${2:?versions.env path required}" value
  value="$(sed -n "s/^${key}=//p" "${file}" | tail -n 1)"
  value="${value%\"}"; value="${value#\"}"
  value="${value%\'}"; value="${value#\'}"
  if [ -z "${value}" ]; then
    printf 'ci-image-ref.sh: %s is not set in %s\n' "${key}" "${file}" >&2
    printf '                 That file is the fleet-wide owner of the CI image tags; a\n' >&2
    printf '                 missing key means the ANTfrastructure pin predates the convention.\n' >&2
    return 1
  fi
  printf '%s' "${value}"
}

# ci_image_ref [linux|windows] [versions.env]
ci_image_ref() {
  local platform="${1:-linux}" file="${2:-${CI_IMAGE_REF_VERSIONS_ENV}}" tag_key prefix tag
  case "${platform}" in
    linux)   tag_key=CI_IMAGE_LINUX_TAG ;;
    windows) tag_key=CI_IMAGE_WINDOWS_TAG ;;
    windows-arm64) tag_key=CI_IMAGE_WINDOWS_ARM64_TAG ;;
    *)
      printf 'ci-image-ref.sh: unknown platform "%s" (expected linux, windows or windows-arm64)\n' "${platform}" >&2
      return 1
      ;;
  esac
  if [ ! -f "${file}" ]; then
    printf 'ci-image-ref.sh: versions.env not found: %s\n' "${file}" >&2
    printf '                 git submodule update --init --recursive third_party/ANTfrastructure\n' >&2
    return 1
  fi
  prefix="$(ci_image_ref_read_key IMAGE_REGISTRY_PREFIX "${file}")" || return 1
  tag="$(ci_image_ref_read_key "${tag_key}" "${file}")" || return 1
  printf '%s:%s\n' "${prefix}" "${tag}"
}

_ci_image_ref_main() {
  local platform=linux
  case "${1:-}" in
    --linux|"") ;;
    --windows) platform=windows ;;
    --windows-arm64) platform=windows-arm64 ;;
    -h|--help)
      printf 'Usage: ci-image-ref.sh [--linux|--windows]\n' >&2
      return 0
      ;;
    *)
      printf 'ci-image-ref.sh: unknown argument "%s" (expected --linux, --windows or --windows-arm64)\n' "$1" >&2
      return 2
      ;;
  esac
  ci_image_ref "${platform}"
}

# Sourceable as a library (ci_image_ref), executable as the one-line printer.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  _ci_image_ref_main "$@"
fi
