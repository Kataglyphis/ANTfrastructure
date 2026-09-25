#!/usr/bin/env bash
# ci-image-ref.sh - print the family CI container image reference.

# versions.env owns the tags (Linux, Windows, the Windows arm64 cross bundle),
# and the four container composite actions carry the composed refs as their
# image input DEFAULTS - so a workflow step that wants the family image omits
# the input and never calls this. This is for callers that CANNOT omit an input
# because they call no action: a raw `docker run`, a local repro, a sweep script.
# Its PowerShell twin is Get-CiImageReference (WindowsContainerImage.Common.psm1).
# tests/test-ci-image-ref.sh holds this script and verify_ci_image_refs.py to the
# same strings; ContainerImage.CiRef.Tests.ps1 holds the twin to versions.env.

# It takes NO consumer root, unlike the other entry points here, and that is
# deliberate rather than an oversight: the only file it reads is THIS repo's
# versions.env, whichever tree is being built. A root parameter would imply a
# per-consumer answer, and there isn't one.
#
#   ci-image-ref.sh                  # the Linux image (default)
#   ci-image-ref.sh --windows        # the Windows image
#   ci-image-ref.sh --windows-arm64  # the Windows arm64 cross bundle (windows-arm64-cross.yml)

# stdout carries the reference and NOTHING else, so it is safe inside a command
# substitution; every diagnostic goes to stderr. A missing key is a hard failure
# rather than an empty string, because an empty image reference reaches
# `docker run` as "run the argument after it as an image" and then fails a long
# way from the cause.
set -euo pipefail

# Overridable for the self-test only; the default is this repo's own copy.
: "${CI_IMAGE_REF_VERSIONS_ENV:=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/01-core/versions.env}"

# PARSED, never sourced, and never routed through load_versions_env: that loader
# lets an already-set environment variable win, which is right for a Dockerfile
# ARG and wrong here - a stray CI_IMAGE_LINUX_TAG in the environment would
# silently redirect every caller to another image. The file is the only answer.
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
