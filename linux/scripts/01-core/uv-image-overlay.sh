#!/usr/bin/env bash
# Install a locked overlay without replacing image packages; see docs/python-ci.md#locked-overlays-on-image-packages
[ -n "${_UV_IMAGE_OVERLAY_LOADED:-}" ] && return 0
_UV_IMAGE_OVERLAY_LOADED=1

_UV_IMAGE_OVERLAY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

uv_image_overlay_cleanup() {
  local status="${1:?exit status required}" path="${2:?temporary path required}"
  if ! rm -rf -- "${path}" || [ -e "${path}" ] || [ -L "${path}" ]; then
    printf 'Failed to remove temporary overlay: %s\n' "${path}" >&2
    [ "${status}" -ne 0 ] || status=1
  fi
  return "${status}"
}

uv_image_overlay_exit() {
  local status="${1:?exit status required}" path="${2:?temporary path required}"
  trap - EXIT
  uv_image_overlay_cleanup "${status}" "${path}" || status=$?
  exit "${status}"
}

uv_image_overlay_verify_modules() {
  local python="${1:?target Python required}" image_root="${2:?image root required}"
  shift 2
  [ "$#" -gt 0 ] || return 1
  "${python}" -I "${_UV_IMAGE_OVERLAY_DIR}/verify-uv-image-modules.py" "${image_root}" "$@"
}

uv_image_overlay_uv() {
  env -u UV_WORKING_DIR -u UV_PROJECT uv "$@"
}

uv_image_overlay_install() {
  local image_python="${1:?image Python required}" target_python="${2:?target Python required}" work="${3:?work directory required}"
  local name
  local -a omit=() export_args=(--locked --no-dev --no-emit-project --format requirements.txt)
  [ -x "${image_python}" ] && [ -x "${target_python}" ] && [ -d "${work}" ] || return 1
  "${target_python}" -I -c 'import sys; sys.exit(sys.prefix == sys.base_prefix)' || return 1
  "${image_python}" -I -m pip --isolated list --format=freeze > "${work}/image-constraints.txt" || return 1
  while IFS='=' read -r name _; do
    [ -z "${name}" ] || omit+=(--no-emit-package "${name}")
  done < "${work}/image-constraints.txt"
  uv_image_overlay_uv export "${export_args[@]}" --no-hashes --output-file "${work}/lock-all.txt" >/dev/null || return 1
  uv_image_overlay_uv export "${export_args[@]}" "${omit[@]}" --no-hashes --output-file "${work}/lock-plan.txt" >/dev/null || return 1
  uv_image_overlay_uv export "${export_args[@]}" "${omit[@]}" --output-file "${work}/lock-install.txt" >/dev/null || return 1
  "${target_python}" -I -m pip --isolated install --dry-run --report "${work}/install-plan.json" \
    --constraint "${work}/image-constraints.txt" --requirement "${work}/lock-plan.txt" || return 1
  "${target_python}" -I "${_UV_IMAGE_OVERLAY_DIR}/verify-uv-image-plan.py" "${work}/lock-plan.txt" \
    "${work}/install-plan.json" "${work}/lock-all.txt" "${work}/image-constraints.txt" || return 1
  uv_image_overlay_uv pip install --python "${target_python}" --no-deps --require-hashes --requirement "${work}/lock-install.txt"
}
