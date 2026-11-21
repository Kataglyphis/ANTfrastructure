#!/usr/bin/env bash
# Controlled extraction transports selected fixture bytes without executing an AppImage runtime.
set -euo pipefail
printf called >> "$APPIMAGE_TRACE"
[ "$1" = --appimage-extract ]
[ "$2" = "$EXPECTED_ENTRY" ]
if [ "${APPIMAGE_FIXTURE:-good}" = rootlink ]; then
  mkdir -p "root-target/$(dirname "$EXPECTED_ENTRY")"
  cp "$EXPECTED_FILE" "root-target/$EXPECTED_ENTRY"
  ln -s root-target squashfs-root
  exit 0
fi
destination="squashfs-root/$EXPECTED_ENTRY"
mkdir -p "$(dirname "$destination")"
case "${APPIMAGE_FIXTURE:-good}" in
  good) cp "$EXPECTED_FILE" "$destination" ;;
  wrong) printf wrong > "$destination" ;;
  missing) : ;;
  fail) exit 15 ;;
  symlink) ln -s "$EXPECTED_FILE" "$destination" ;;
  *) exit 19 ;;
esac
