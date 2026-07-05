#!/usr/bin/env bash
# generate-patches.sh — List patch files and document how to regenerate them.
#
# Usage: bash generate-patches.sh [--component <name>]
#
# Lists the .patch files under patches/ (all, or just one component's) and prints
# the regeneration workflow. Patches are NOT auto-generated here: to regenerate
# after a version bump, re-run the component's build with APPLY_PATCH_TRACE=1 to
# see which patches apply, then diff the modified tree against a fresh upstream
# clone at the pinned version.
#
# Components: gstreamer, tvm, litert, opencv, libcamera, onnxruntime,
#             cerbero, llvm, torchvision, vulkan
set -euo pipefail

# This script lives in the patches dir; the per-component .patch files sit
# directly under it (patches/<component>/*.patch).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCHES_DIR="${SCRIPT_DIR}"

component=""
while [ $# -gt 0 ]; do
  case "$1" in
    --component) component="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

search_root="${PATCHES_DIR}"
if [ -n "${component}" ]; then
  echo "Component: ${component}"
  search_root="${PATCHES_DIR}/${component}"
else
  echo "All components"
fi
echo ""
echo "To regenerate: re-run the component build with APPLY_PATCH_TRACE=1, then"
echo "diff the modified tree against a fresh upstream clone at the pinned version."
echo ""
echo "Existing patch files under ${PATCHES_DIR}:"
find "${search_root}" -name '*.patch' 2>/dev/null | sort | while read -r f; do
  echo "  $(echo "$f" | sed "s|${PATCHES_DIR}/||") ($(wc -l < "$f") lines)"
done
