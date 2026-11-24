#!/usr/bin/env bash
# check-install-tree.sh <root> [--allow <path below root>]...: fails when an install tree ships build-time files (CON299).
set -euo pipefail

# Headers, CMake and pkg-config packages, import and static libraries; New-PortableBundle's -ForbidBuildTimeFiles uses the same rule.
BUILD_TIME='^(usr/)?(include|lib[^/]*(/[^/]+)?/(cmake|pkgconfig)|share/pkgconfig)/|\.(lib|a)$'

root="${1:?usage: check-install-tree.sh <root> [--allow <path>]...}"
shift
allow=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --allow) allow+=("${2%/}"); shift 2 ;;
    *) echo "check-install-tree.sh: unknown argument $1" >&2; exit 2 ;;
  esac
done
[[ -d "${root}" ]] || { echo "check-install-tree.sh: ${root} is no directory" >&2; exit 2; }

found=()
while IFS= read -r rel; do
  kept=0
  for a in "${allow[@]+"${allow[@]}"}"; do
    if [[ "${rel}" == "${a}" || "${rel}" == "${a}/"* ]]; then kept=1; fi
  done
  [[ "${kept}" == 1 ]] || found+=("${rel}")
done < <(cd "${root}" && { find . -type f | sed 's#^\./##' | LC_ALL=C sort | grep -E "${BUILD_TIME}" || true; })

if [[ ${#found[@]} -gt 0 ]]; then
  echo "FAIL: ${root} ships ${#found[@]} build-time file(s) no user of the product needs: ${found[*]:0:8}" >&2
  echo "Install only runtime files, or pass --allow for what the product ships on purpose." >&2
  exit 1
fi
echo "OK: ${root} ships no build-time file"
