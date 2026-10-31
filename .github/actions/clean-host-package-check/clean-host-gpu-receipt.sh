#!/usr/bin/env bash
# The trusted caller must supply the upload's immutable ID, digest and exact expected filenames.
set -euo pipefail

mode="${1:?expected validate, prepare or finish}"
id="${GPU_ARTIFACT_ID:-}"
optional=("${GPU_ARTIFACT_DIGEST:-}" "${GPU_ARTIFACT_FILES:-}" "${GPU_VENDOR:-}" "${GPU_ARCH:-}"
  "${GPU_RECEIPT:-}" "${GPU_MAX_BYTES:-}" "${GPU_MAX_RATIO:-}")

die() { printf '%s\n' "$1" >&2; exit 1; }

validate_inputs() {
  local value
  if [[ -z "$id" ]]; then
    [[ "${GPU_CHECK_NAME:-clean-host-inference}" == clean-host-inference ]] || die 'GPU profile requires artifact-id'
    for value in "${optional[@]}"; do
      [[ -z "$value" ]] || die 'GPU receipt inputs require artifact-id'
    done
    [[ "$mode" == validate ]] || die 'GPU receipt mode requires artifact-id'
    return 0
  fi
  for value in "${optional[@]}"; do
    [[ -n "$value" ]] || die 'GPU receipt mode requires all identity, filename and limit inputs'
  done
  [[ "$id" =~ ^[1-9][0-9]*$ && -z "${PACKAGE_SUBDIR:-}" ]] || die 'Expected one artifact ID and a flat package directory'
  [[ "$GPU_ARTIFACT_DIGEST" =~ ^(sha256:)?[0-9a-f]{64}$ && "$GPU_MAX_BYTES" =~ ^[1-9][0-9]*$ && "$GPU_MAX_RATIO" =~ ^[1-9][0-9]*$ ]] || die 'Invalid GPU artifact digest or expansion limit'
  case "$GPU_VENDOR:$GPU_ARCH" in nvidia:x64|nvidia:arm64|amd:x64) ;; *) die 'Unsupported Linux GPU tuple' ;; esac
  [[ "$GPU_RECEIPT" == /* ]] || die 'GPU receipt path must be absolute'
  for value in "${DEB_GLOB:-}" "${DEB_COMMAND:-}" "${TARBALL_GLOB:-}" "${TARBALL_COMMAND:-}" "${APPIMAGE_GLOB:-}" "${APPIMAGE_COMMAND:-}"; do
    [[ -n "$value" ]] || die 'GPU clean-host receipts require DEB, tar and AppImage checks'
  done
}

validate_packages() {
  local name debs=0 tarballs=0 appimages=0
  while IFS= read -r name || [[ -n "$name" ]]; do
    [[ -z "$name" ]] && continue
    if [[ "$name" == *.deb && -z "${name##$DEB_GLOB}" ]]; then debs=$((debs + 1))
    elif [[ "$name" == *.tar.gz && -z "${name##$TARBALL_GLOB}" ]]; then tarballs=$((tarballs + 1))
    elif [[ "$name" == *.AppImage && -z "${name##$APPIMAGE_GLOB}" ]]; then appimages=$((appimages + 1))
    else die 'GPU receipt files must be exactly the tested DEB, tarball and AppImage'
    fi
  done <<< "$GPU_ARTIFACT_FILES"
  [[ "$debs:$tarballs:$appimages" == 1:1:1 ]] || die 'GPU receipt requires one of each tested package type'
}

validate_inputs
[[ -n "$id" ]] || exit 0
validate_packages
[[ "$mode" != validate ]] || exit 0

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
python_root="$root/shared/python"
before="${GPU_BEFORE_RECEIPT:-${RUNNER_TEMP:?}/clean-host-gpu-before.json}"
packages="${GPU_PACKAGES_DIR:-${RUNNER_TEMP:?}/clean-host-packages}"
check="${GPU_CHECK_NAME:-clean-host-inference}"
case "$check" in clean-host-inference|gpu-model-inference) ;; *) die 'Unsupported GPU receipt check' ;; esac
identity=(--repository "${GITHUB_REPOSITORY:?}" --revision "${GITHUB_SHA:?}" --run-id "${GITHUB_RUN_ID:?}"
  --run-attempt "${GITHUB_RUN_ATTEMPT:?}" --artifact-id "$id" --artifact-digest "$GPU_ARTIFACT_DIGEST"
  --platform linux --arch "$GPU_ARCH" --vendor "$GPU_VENDOR")
files=()
while IFS= read -r name || [[ -n "$name" ]]; do
  [[ -z "$name" ]] || files+=(--file "$name")
done <<< "$GPU_ARTIFACT_FILES"
[[ ${#files[@]} -gt 0 ]] || die 'No GPU package filenames supplied'
case "$mode" in
  prepare)
    [[ -d "${GPU_ARCHIVE_DIR:?}" && ! -L "$GPU_ARCHIVE_DIR" ]] || die 'Expected a real artifact archive directory'
    shopt -s nullglob dotglob
    archives=("$GPU_ARCHIVE_DIR"/*)
    [[ ${#archives[@]} -eq 1 && -f "${archives[0]}" && ! -L "${archives[0]}" ]] || die 'Expected exactly one downloaded artifact archive'
    python3 -I "$python_root/prepare_gpu_artifact.py" --archive "${archives[0]}" --output "$packages" \
      --before-receipt "$before" --max-uncompressed-bytes "$GPU_MAX_BYTES" --max-compression-ratio "$GPU_MAX_RATIO" \
      "${identity[@]}" "${files[@]}"
    ;;
  finish)
    python3 -I "$python_root/gpu_artifact_receipt.py" verify --directory "$packages" --receipt "$before" \
      --check before-check "${identity[@]}" "${files[@]}"
    python3 -I "$python_root/gpu_artifact_receipt.py" create --directory "$packages" --receipt "$GPU_RECEIPT" \
      --check "$check" "${identity[@]}" "${files[@]}"
    ;;
  *) die 'Expected validate, prepare or finish' ;;
esac
