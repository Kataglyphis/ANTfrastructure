#!/usr/bin/env bash
# Detect stale compatibility exports; this does not validate package runtime behavior.
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "${1:-${script_dir}/../..}" && pwd)"
source "${script_dir}/renovate-uv-exports.sh"
source "${script_dir}/01-core/uv-image-overlay.sh"
rows="$(python3 "${script_dir}/renovate_planner.py" uv-exports "${root}")"
[ -n "${rows}" ] || { echo 'No uv compatibility exports configured' >&2; exit 1; }
tmp="$(mktemp -d)"
trap 'uv_image_overlay_exit "$?" "${tmp}"' EXIT
while IFS=$'\t' read -r project output; do
  [ -n "${project}" ] || continue
  uv_export_locked_to_file "${root}" "${project}" "${tmp}/requirements.txt"
  [ -s "${tmp}/requirements.txt" ] || { echo "Empty uv export: ${project}" >&2; exit 1; }
  if ! cmp -s "${tmp}/requirements.txt" "${root}/${output}"; then
    echo "Stale uv compatibility export: ${output}" >&2
    exit 1
  fi
  echo "Verified uv compatibility export: ${output}"
done <<< "${rows}"
