#!/usr/bin/env bash
set -euo pipefail

# Runs before the Android and Rust COPYs. See docs/artifact-copy-completeness.md § The host payload stays with the host that runs it

# Read by smoke-android.sh, install-android-emulator.sh and the contract gate; android-sdk.sh writes the same file.
ANDROID_PAYLOAD_OFF_MARKER=".android-payload-off"

# Beside the script in the Dockerfile's bind mount, in 01-core from a checkout.
_host_payload_platform() {
  local here p
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  for p in "${here}/platform.sh" "${here}/../01-core/platform.sh"; do
    # shellcheck disable=SC1090
    [ ! -r "${p}" ] || { source "${p}"; break; }
  done
  declare -F arch_rust_target_triple_for >/dev/null 2>&1
}

# Empties a directory but keeps it, so the unconditional COPY still finds its source.
_empty_dir() {
  local dir="$1" keep="${2:-}"
  [ -d "${dir}" ] || return 0
  if [ -n "${keep}" ]; then
    find "${dir}" -mindepth 1 -maxdepth 1 ! -name "${keep}" -exec rm -rf {} +
  else
    find "${dir}" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  fi
}

# Same rule as ensure_native_rust_toolchain, applied before the COPY instead of after it.
prune_foreign_rust() {
  local rustup="$1" cargo="$2" target_arch="$3" triple have="" t
  triple="$(arch_rust_target_triple_for "${target_arch}")"
  if [ ! -d "${rustup}/toolchains" ]; then
    echo "host-payload: ${rustup} holds no toolchains; nothing to prune"
    return 0
  fi
  if compgen -G "${rustup}/toolchains/*-${triple}" >/dev/null; then
    echo "host-payload: keeping ${rustup} (it holds a ${triple} toolchain)"
    return 0
  fi
  for t in "${rustup}"/toolchains/*; do have+="${t##*/} "; done
  echo "host-payload: emptying ${rustup} and ${cargo} but its registry (${have}-- ${target_arch} runs ${triple}, which the package stage installs)"
  _empty_dir "${rustup}"
  _empty_dir "${cargo}" registry
}

# The SDK's host tools and NDK are linux-x86_64 only, and /opt/android is useless without them.
prune_android_payload() {
  local sdk="$1" payload="$2" target_arch="$3"
  echo "host-payload: emptying ${sdk} and ${payload} (HOST_PAYLOAD=off for ${target_arch})"
  _empty_dir "${sdk}"
  if [ -f "${payload}/${ANDROID_PAYLOAD_OFF_MARKER}" ]; then
    _empty_dir "${payload}" "${ANDROID_PAYLOAD_OFF_MARKER}"
    echo "host-payload: keeping the existing ${payload}/${ANDROID_PAYLOAD_OFF_MARKER}"
    return 0
  fi
  _empty_dir "${payload}"
  mkdir -p "${payload}"
  {
    printf 'reason=the x86_64-host Android SDK and its payloads stay out of the %s image (HOST_PAYLOAD=off)\n' "${target_arch}"
    printf 'target_arch=%s\n' "${target_arch}"
    printf 'skipped=sdk,ndk,gstreamer,onnxruntime,litert,opencv,iree,smoke\n'
  } > "${payload}/${ANDROID_PAYLOAD_OFF_MARKER}"
}

main() {
  local target_arch="${1:-${TARGET_ARCH:-${TARGETARCH:-}}}"
  local root="${2:-}"
  local mode="${HOST_PAYLOAD:-on}"

  _host_payload_platform || {
    echo "ERROR: prune-host-payload.sh found no platform.sh defining arch_rust_target_triple_for" >&2
    exit 1
  }
  arch_rust_target_triple_for "${target_arch}" >/dev/null 2>&1 || {
    echo "ERROR: no Rust target triple for target arch '${target_arch}'" >&2
    exit 1
  }
  case "${mode}" in
    on)
      echo "host-payload: HOST_PAYLOAD=on for ${target_arch}; the Android SDK, its payloads and the Rust toolchain are copied as built"
      return 0 ;;
    off) ;;
    *)
      echo "ERROR: HOST_PAYLOAD='${mode}' (want on or off)" >&2
      exit 1 ;;
  esac
  prune_foreign_rust "${root}/usr/local/rustup" "${root}/usr/local/cargo" "${target_arch}"
  prune_android_payload "${root}/opt/android-sdk" "${root}/opt/android" "${target_arch}"
}

main "$@"
