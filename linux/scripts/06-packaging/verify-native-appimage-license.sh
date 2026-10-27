#!/usr/bin/env bash
# Checks an AppImage payload on its native architecture, not third-party compliance.
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${script_dir}/../01-core/platform.sh"
if [ "$#" -ne 4 ]; then
  printf 'Usage: %s APPIMAGE ARCH ENTRY LICENSE\n' "$0" >&2
  exit 2
fi
image="$(realpath -e -- "$1")"
target="$(arch_normalize "$2")"
host="$(arch_normalize "$(uname -m)")"
entry="$3"
license="$(realpath -e -- "$4")"
case "$entry" in
  ''|/*|*/|*//*|*\\*|*'*'*|*'?'*|*'['*|*']'*|*':'*|*[[:cntrl:]]*) printf 'Invalid AppImage entry: %s\n' "$entry" >&2; exit 2 ;;
esac
IFS=/ read -r -a entry_parts <<< "$entry"
for part in "${entry_parts[@]}"; do
  case "$part" in .|..) printf 'Invalid AppImage entry: %s\n' "$entry" >&2; exit 2 ;; esac
done
case "$target" in amd64|arm64) ;; *) printf 'Unsupported AppImage architecture: %s\n' "$2" >&2; exit 2 ;; esac
if [ "$target" != "$host" ]; then
  printf 'AppImage verification requires a native %s host, got %s\n' "$target" "$host" >&2
  exit 1
fi
[ -x "$image" ] || { printf 'AppImage is not executable: %s\n' "$image" >&2; exit 1; }
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
(
  cd "$work"
  "$image" --appimage-extract "$entry" > /dev/null
  python3 "${script_dir}/../verify_package_license.py" squashfs-root --require "${entry}=${license}"
)
rm -rf -- "$work"
trap - EXIT
