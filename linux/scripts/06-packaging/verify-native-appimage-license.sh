#!/usr/bin/env bash
# Checks an AppImage payload on its native architecture, not third-party compliance.
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${script_dir}/../01-core/platform.sh"
source "${script_dir}/appimage-verification.sh"
declare image work
appimage_require_args "$#" 4 "$0" 'APPIMAGE ARCH ENTRY LICENSE'
appimage_init "$1" "$2"
entry="$3"
license="$(realpath -e -- "$4")"
appimage_validate_path "$entry" 'AppImage entry'
appimage_require_native "$2"
appimage_create_work
(
  cd "$work"
  "$image" --appimage-extract "$entry" > /dev/null
  python3 "${script_dir}/../verify_package_license.py" squashfs-root --require "${entry}=${license}"
)
rm -rf -- "$work"
trap - EXIT
