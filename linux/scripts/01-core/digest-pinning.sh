#!/usr/bin/env bash
# digest-pinning.sh — registry manifest digest resolution for pinned FROM refs.
[ -n "${_DIGEST_PINNING_SH_LOADED:-}" ] && return 0
_DIGEST_PINNING_SH_LOADED=1
#
# Provides:
#   registry_pin_ref()            — resolve registry digest, print "repo@sha256:..."
#   _has_digest_pinned_base()     — detect if args already contain a digest-pinned ref

_TAG_NAMING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolve the registry-resolvable manifest digest of a pushed tag and print a
# digest-pinned reference like "repo@sha256:...".
#
# This intentionally uses `nerdctl manifest inspect --verbose` (which reports the
# digest of the manifest as it exists in the registry) rather than the local
# image store's RepoDigests. On this host BuildKit pushes a converted
# `docker.v2+json` manifest whose digest differs from the local OCI manifest, so
# RepoDigests is NOT registry-resolvable and must not be used for `FROM` pinning.
registry_pin_ref() {
  local nerdctl_bin image_ref

  if [ "$#" -eq 1 ]; then
    nerdctl_bin="${NERDCTL_BIN:-nerdctl}"
    image_ref="$1"
  else
    nerdctl_bin="$1"
    image_ref="$2"
  fi

  local repo digest
  repo="${image_ref%:*}"

  if ! command -v python3 >/dev/null 2>&1; then
    printf '[ERROR] python3 is required for registry digest resolution\n' >&2
    return 1
  fi

  local digest_script="${_TAG_NAMING_DIR}/registry-digest.py"
  if [ ! -f "${digest_script}" ]; then
    printf '[ERROR] registry-digest.py not found at %s\n' "${digest_script}" >&2
    return 1
  fi

  local err_output
  err_output="$(mktemp)"
  digest="$("${nerdctl_bin}" manifest inspect --verbose "${image_ref}" 2>"${err_output}" \
    | python3 "${digest_script}" 2>"${err_output}")"

  if [ -z "${digest}" ]; then
    printf '[ERROR] Could not resolve registry digest for %s\n' "${image_ref}" >&2
    if [ -s "${err_output}" ]; then
      printf '[ERROR] Registry/digest diagnostic output:\n' >&2
      cat "${err_output}" >&2
    fi
    rm -f "${err_output}"
    return 1
  fi
  rm -f "${err_output}"

  printf '%s@%s' "${repo}" "${digest}"
}

# Detect whether the extra build args include a digest-pinned BASE_IMAGE.
# Matches --build-arg BASE_IMAGE=...@sha256:... specifically (not any arg with
# a sha256 prefix). When the base is content-addressed, --pull is unnecessary
# because the digest uniquely identifies the image and can never resolve to a
# stale version.
_has_digest_pinned_base() {
  local arg
  for arg in "$@"; do
    case "${arg}" in
      BASE_IMAGE=*@sha256:*) return 0 ;;
    esac
  done
  return 1
}
