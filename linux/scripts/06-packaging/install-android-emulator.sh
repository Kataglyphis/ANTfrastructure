#!/usr/bin/env bash
set -euo pipefail

# The Android emulator and one x86_64 system image, amd64 only: docs/consumer-image-contract.md#the-android-emulator-runs-on-amd64-with-kvm

: "${ANDROID_HOME:=/opt/android-sdk}"
: "${ANDROID_PAYLOAD_DIR:=/opt/android}"
: "${TEST_RUNTIMES_CACHE_DIR:=}"
: "${TR_CORE_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../01-core" 2>/dev/null && pwd || echo /opt/scripts/core)}"
: "${VERSIONS_ENV:=${TR_CORE_DIR}/versions.env}"

emu_url() {
  printf 'https://dl.google.com/android/repository/emulator-linux_x64-%s.zip' "$1"
}

# <api> <revision>
emu_sysimg_url() {
  printf 'https://dl.google.com/android/repository/sys-img/google_apis/x86_64-%s_r%02d.zip' "$1" "$2"
}

emu_record_off() {
  mkdir -p "${ANDROID_PAYLOAD_DIR}"
  printf 'reason=%s\narch=%s\n' "$1" "$2" > "${ANDROID_PAYLOAD_DIR}/.android-emulator-off"
}

# <dir> <key>: one value from the package's source.properties.
emu_prop() {
  sed -n "s/^$2=//p" "$1/source.properties" 2>/dev/null | head -1
}

# <url> <sha256> <parent> <top>: the zip's single top directory lands at <parent>/<top>.
emu_unpack() {
  local tmp
  tmp="$(mktemp -d)"
  if ! download_verified_cached "$1" "$2" "${tmp}/pkg.zip" "${TEST_RUNTIMES_CACHE_DIR}"; then
    rm -rf "${tmp}"
    return 1
  fi
  mkdir -p "$3"
  rm -rf "${3:?}/${4:?}"
  unzip -q "${tmp}/pkg.zip" -d "$3"
  rm -rf "${tmp}"
  [ -d "$3/$4" ] || { echo "ERROR: ${1##*/} unpacked no $4/ under $3" >&2; return 1; }
}

# <dir> <key> <want>
_emu_expect() {
  local got
  got="$(emu_prop "$1" "$2")"
  [ "${got}" = "$3" ] || { echo "ERROR: $1 has $2=${got:-<none>}, the pin says $3" >&2; return 1; }
}

emu_verify() {
  local emu_dir="${ANDROID_HOME}/emulator" img f so missing="" out
  img="${ANDROID_HOME}/system-images/android-${ANDROID_EMULATOR_API}/google_apis/x86_64"
  _emu_expect "${emu_dir}" Pkg.Revision "${ANDROID_EMULATOR_VERSION}"
  _emu_expect "${emu_dir}" Pkg.BuildId "${ANDROID_EMULATOR_BUILD}"
  _emu_expect "${img}" AndroidVersion.ApiLevel "${ANDROID_EMULATOR_API}"
  _emu_expect "${img}" SystemImage.TagId google_apis
  _emu_expect "${img}" SystemImage.Abi x86_64
  _emu_expect "${img}" Pkg.Revision "${ANDROID_EMULATOR_SYSIMG_REVISION}"
  # The emulator puts its own lib64 on the loader path, so the check does too.
  for f in emulator qemu/linux-x86_64/qemu-system-x86_64-headless; do
    [ -x "${emu_dir}/${f}" ] || { echo "ERROR: ${emu_dir}/${f} is missing" >&2; return 1; }
    while IFS= read -r so; do missing+=" ${f}:${so}"; done \
      < <(elf_unresolved_needed --transitive "${emu_dir}/${f}" "${emu_dir}/lib64")
  done
  [ -z "${missing}" ] || { echo "ERROR: unresolved libraries:${missing}" >&2; return 1; }
  out="$("${emu_dir}/emulator" -version 2>&1 || true)"
  case "${out}" in
    *"version ${ANDROID_EMULATOR_VERSION}"*"build_id ${ANDROID_EMULATOR_BUILD}"*) ;;
    *) echo "ERROR: emulator -version says '$(printf '%s\n' "${out}" | head -1)'" >&2; return 1 ;;
  esac
  echo "OK: emulator ${ANDROID_EMULATOR_VERSION} and system-images;android-${ANDROID_EMULATOR_API};google_apis;x86_64 r${ANDROID_EMULATOR_SYSIMG_REVISION}"
}

main() {
  local arch lib
  for lib in downloads.sh load-versions-env.sh platform.sh; do
    # shellcheck source=/dev/null
    source "${TR_CORE_DIR}/${lib}"
  done
  load_versions_env "${VERSIONS_ENV}"
  : "${EMU_ARCH:=$(dpkg --print-architecture)}"
  arch="${EMU_ARCH}"
  if [ "${arch}" != amd64 ]; then
    emu_record_off "Google publishes the Linux emulator for x86_64 hosts only, and it needs KVM" "${arch}"
    echo "NOTE: no Android emulator on ${arch}"
    return 0
  fi
  if [ -f "${ANDROID_PAYLOAD_DIR}/.android-payload-off" ]; then
    emu_record_off "this image ships no Android SDK (.android-payload-off)" "${arch}"
    echo "NOTE: no Android SDK in this image, so no emulator either"
    return 0
  fi
  [ -d "${ANDROID_HOME}/platform-tools" ] || { echo "ERROR: ${ANDROID_HOME} has no platform-tools; the emulator needs adb" >&2; return 1; }
  : "${ANDROID_EMULATOR_VERSION:?}" "${ANDROID_EMULATOR_BUILD:?}" "${ANDROID_EMULATOR_SHA256:?}"
  : "${ANDROID_EMULATOR_API:?}" "${ANDROID_EMULATOR_SYSIMG_REVISION:?}" "${ANDROID_EMULATOR_SYSIMG_SHA256:?}"

  rm -f "${ANDROID_PAYLOAD_DIR}/.android-emulator-off"
  emu_unpack "$(emu_url "${ANDROID_EMULATOR_BUILD}")" "${ANDROID_EMULATOR_SHA256}" "${ANDROID_HOME}" emulator
  emu_unpack "$(emu_sysimg_url "${ANDROID_EMULATOR_API}" "${ANDROID_EMULATOR_SYSIMG_REVISION}")" \
    "${ANDROID_EMULATOR_SYSIMG_SHA256}" "${ANDROID_HOME}/system-images/android-${ANDROID_EMULATOR_API}/google_apis" x86_64
  emu_verify
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
