#!/usr/bin/env bash
# Registry manifest digests for pinned FROM refs.
[ -n "${_DIGEST_PINNING_SH_LOADED:-}" ] && return 0
_DIGEST_PINNING_SH_LOADED=1

_TAG_NAMING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Prints repo@sha256 from the registry, never local RepoDigests: the pushed, converted manifest has another digest.
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

  # One stderr file per stage: they run concurrently and would garble a shared one.
  local inspect_err digest_err
  inspect_err="$(mktemp)"
  digest_err="$(mktemp)"
  digest="$("${nerdctl_bin}" manifest inspect --verbose "${image_ref}" 2>"${inspect_err}" \
    | python3 "${digest_script}" 2>"${digest_err}")"

  if [ -z "${digest}" ]; then
    printf '[ERROR] Could not resolve registry digest for %s\n' "${image_ref}" >&2
    if [ -s "${inspect_err}" ] || [ -s "${digest_err}" ]; then
      printf '[ERROR] Registry/digest diagnostic output:\n' >&2
      cat "${inspect_err}" "${digest_err}" >&2
    fi
    rm -f "${inspect_err}" "${digest_err}"
    return 1
  fi
  rm -f "${inspect_err}" "${digest_err}"

  printf '%s@%s' "${repo}" "${digest}"
}

# A digest-pinned BASE_IMAGE can never resolve stale, so --pull is unnecessary.
_has_digest_pinned_base() {
  local arg
  for arg in "$@"; do
    case "${arg}" in
      BASE_IMAGE=*@sha256:*) return 0 ;;
    esac
  done
  return 1
}
