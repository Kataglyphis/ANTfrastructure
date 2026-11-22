#!/usr/bin/env bash
# Controlled imports exercise the shared checkout transport without installing a Flatpak.
set -euo pipefail
: "${FAKE_FLATPAK_TREE:=}"
: "${FAKE_OSTREE_CHECKOUT_RC:=0}"
if [ "${0##*/}" = flatpak ]; then exit "${FAKE_FLATPAK_RC:-0}"; fi
case "$1" in
  init) exit 0 ;;
  refs)
    printf '%s\n' "${FAKE_REF:-app/org.example.Demo/x86_64/stable}" ;;
  checkout)
    [ "$FAKE_OSTREE_CHECKOUT_RC" -eq 0 ] || exit "$FAKE_OSTREE_CHECKOUT_RC"
    target="${!#}"
    if [ -n "$FAKE_FLATPAK_TREE" ]; then
      mkdir -p "$target"
      cp -a "$FAKE_FLATPAK_TREE/." "$target/"
    else
      mkdir -p "$target/files/lib/demo"
      cp "$FAKE_LICENSE" "$target/files/lib/demo/LICENSE"
    fi ;;
  *) exit 1 ;;
esac
