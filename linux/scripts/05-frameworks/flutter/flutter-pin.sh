#!/usr/bin/env bash
# flutter-pin.sh - resolve the Flutter pin ContainerHub owns.
#
# versions.env pins FLUTTER_VERSION *together with* the tarball's
# FLUTTER_SDK_SHA256. The two are one pin: overriding only the version can never
# verify, because the sha still belongs to the old tarball. Consumers used to
# copy the version into their own files, those copies drifted, and
# setup-flutter.sh then failed with a bare `Checksum verification FAILED` that
# named neither file — one consumer had three lanes red for two weeks that way.
#
# Usage — call it as a plain command, never in $(...):
#   source 05-frameworks/flutter/flutter-pin.sh
#   flutter_resolve_pin          # exports FLUTTER_VERSION + FLUTTER_SDK_SHA256
# In a command substitution the exports land in a subshell and are lost, and the
# caller silently proceeds unpinned.
#
# An already-set FLUTTER_VERSION wins and is treated as a deliberate one-off:
# the sha is then left unset on purpose, so setup-flutter.sh reports the
# mismatch by name instead of emitting that bare checksum error.

[ -n "${_FLUTTER_PIN_SH_LOADED:-}" ] && return 0
_FLUTTER_PIN_SH_LOADED=1

_FLUTTER_PIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Prints the absolute path of versions.env, probing the baked container layout
# before the repo layout — the same order install-deps-preamble.sh uses.
flutter_pin_versions_env() {
  local candidate
  for candidate in \
    "/opt/scripts/core/versions.env" \
    "${_FLUTTER_PIN_DIR}/../../01-core/versions.env"
  do
    if [ -f "$candidate" ]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  echo "Error: versions.env not found in /opt/scripts/core or ${_FLUTTER_PIN_DIR}/../../01-core" >&2
  return 1
}

flutter_resolve_pin() {
  local versions_env pinned_version pinned_sha
  versions_env="$(flutter_pin_versions_env)" || return 1

  pinned_version="$(sed -n 's/^FLUTTER_VERSION=//p' "$versions_env")"
  pinned_sha="$(sed -n 's/^FLUTTER_SDK_SHA256=//p' "$versions_env")"

  if [ -z "$pinned_version" ] || [ -z "$pinned_sha" ]; then
    echo "Error: FLUTTER_VERSION and FLUTTER_SDK_SHA256 are not both pinned in" >&2
    echo "       ${versions_env}. They are one pin; fix it there." >&2
    return 1
  fi

  if [ -n "${FLUTTER_VERSION:-}" ]; then
    # Deliberate override: leave the sha unset so the mismatch is named.
    return 0
  fi

  export FLUTTER_VERSION="$pinned_version"
  export FLUTTER_SDK_SHA256="$pinned_sha"
  echo "[Info] Flutter ${FLUTTER_VERSION} (pinned in ${versions_env})." >&2
}
