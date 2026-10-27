#!/usr/bin/env bash
# Stages and verifies the wheel notices of bundled native ORT, not other dependencies.
_ORT_WHEEL_LICENSE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

stage_ort_wheel_licenses() {
  local bundle="${1:?bundle required}" library
  local -a libraries=()
  for library in "$bundle"/lib/libonnxruntime*.so*; do
    [ -f "$library" ] || continue
    libraries+=(--library "$library")
  done
  if [ "${#libraries[@]}" -eq 0 ]; then
    printf 'No bundled ONNX Runtime libraries at %s/lib\n' "$bundle" >&2
    return 1
  fi
  python3 "${_ORT_WHEEL_LICENSE_DIR}/stage-ort-wheel-licenses.py" \
    --wheel-dir "${ORT_CHAIN_WHEEL_DIR:-/opt/onnxruntime-wheels}" --destination "$bundle" \
    --strip "${STRIP:-strip}" "${libraries[@]}"
}

verify_ort_wheel_package_licenses() {
  local artifact="${1:?artifact required}" bundle="${2:?bundle required}" prefix="${3:?package prefix required}"
  local name
  local -a rules=()
  for name in LICENSE ThirdPartyNotices.txt; do
    rules+=(--require "${prefix%/}/licenses/onnxruntime/${name}=${bundle}/licenses/onnxruntime/${name}")
  done
  python3 "${_ORT_WHEEL_LICENSE_DIR}/../verify_package_license.py" "$artifact" "${rules[@]}"
}

verify_ort_wheel_appimage_licenses() {
  local artifact="${1:?artifact required}" bundle="${2:?bundle required}" arch="${3:?architecture required}" prefix="${4:?package prefix required}" name
  [ "$prefix" != . ] || prefix=''
  for name in LICENSE ThirdPartyNotices.txt; do
    bash "${_ORT_WHEEL_LICENSE_DIR}/verify-native-appimage-license.sh" "$artifact" "$arch" \
      "${prefix:+${prefix%/}/}licenses/onnxruntime/${name}" "${bundle}/licenses/onnxruntime/${name}" || return $?
  done
}
