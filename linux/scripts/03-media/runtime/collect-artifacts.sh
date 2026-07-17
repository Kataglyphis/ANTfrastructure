#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# WHEELS_DIR (and the media path env) come from the canonical media-env.sh.
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${_SCRIPT_DIR}/media-env.sh"

collect_component_wheels() {
  local source_dir="$1"

  [ -d "${source_dir}" ] || return 0
  mv "${source_dir}"/*.whl "${WHEELS_DIR}/" 2>/dev/null || true
}

wheel_source_dirs=(
  /usr/local/lib/onnxruntime-cpu/wheels
  /usr/local/lib/onnxruntime-genai/wheels
  /usr/local/lib/onnxruntime-gpu/wheels
  /opt/opencv5/wheels
  /opt/app-wheels
  /opt/litert-wheels
  /opt/tvm-wheels
  /opt/libcamera/wheels
)

mkdir -p "${WHEELS_DIR}"

for wheel_source_dir in "${wheel_source_dirs[@]}"; do
  collect_component_wheels "${wheel_source_dir}"
done

rm -rf "${wheel_source_dirs[@]}"
