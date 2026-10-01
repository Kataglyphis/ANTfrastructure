#!/usr/bin/env bash
set -euo pipefail

# create|start|stop an AVD on the image's x86_64 system image (amd64, /dev/kvm): docs/consumer-image-contract.md#the-android-emulator-runs-on-amd64-with-kvm

: "${ANDROID_HOME:?ANDROID_HOME is not set}"
: "${ANDROID_USER_HOME:=${HOME}/.android}"
: "${ANDROID_AVD_HOME:=${ANDROID_USER_HOME}/avd}"
: "${AVD_PORT:=5554}"
: "${AVD_BOOT_TIMEOUT:=600}"
: "${AVD_KVM_DEVICE:=/dev/kvm}"
: "${AVD_CORES:=4}"
: "${AVD_RAM_MB:=4096}"
: "${AVD_DATA_SIZE:=6G}"
export ANDROID_SDK_ROOT="${ANDROID_HOME}" ANDROID_USER_HOME ANDROID_AVD_HOME

avd_usage() {
  echo "usage: $(basename "$0") create|start|stop [name]   (default name: kataglyphis)" >&2
  return 2
}

# The one installed x86_64 system image, relative to ANDROID_HOME (the AVD's image.sysdir.1).
avd_sysimg() {
  local found
  found="$(find "${ANDROID_HOME}/system-images" -mindepth 3 -maxdepth 3 -type d -name x86_64 2>/dev/null | sort || true)"
  case "$(printf '%s' "${found}" | grep -c . || true)" in
    1) printf '%s' "${found#"${ANDROID_HOME}/"}" ;;
    0) echo "ERROR: no x86_64 system image under ${ANDROID_HOME}/system-images (the emulator ships in the amd64 image only)" >&2; return 1 ;;
    *) echo "ERROR: more than one x86_64 system image; create the AVD with avdmanager instead:" >&2; printf '%s\n' "${found}" >&2; return 1 ;;
  esac
}

# A hand-written AVD: avdmanager does not recognise an emulator installed from its zip.
avd_create() {
  local name="$1" rel api tag dir
  rel="$(avd_sysimg)"
  api="$(sed -n 's/^AndroidVersion.ApiLevel=//p' "${ANDROID_HOME}/${rel}/source.properties")"
  tag="$(sed -n 's/^SystemImage.TagId=//p' "${ANDROID_HOME}/${rel}/source.properties")"
  dir="${ANDROID_AVD_HOME}/${name}.avd"
  mkdir -p "${dir}"
  printf 'avd.ini.encoding=UTF-8\npath=%s\npath.rel=avd/%s.avd\ntarget=android-%s\n' "${dir}" "${name}" "${api}" \
    > "${ANDROID_AVD_HOME}/${name}.ini"
  cat > "${dir}/config.ini" <<EOF
AvdId=${name}
avd.ini.displayname=${name}
avd.ini.encoding=UTF-8
abi.type=x86_64
hw.cpu.arch=x86_64
hw.cpu.ncore=${AVD_CORES}
hw.ramSize=${AVD_RAM_MB}
disk.dataPartition.size=${AVD_DATA_SIZE}
hw.gpu.enabled=yes
hw.gpu.mode=swiftshader_indirect
hw.keyboard=yes
hw.lcd.width=1080
hw.lcd.height=1920
hw.lcd.density=420
image.sysdir.1=${rel}/
tag.id=${tag}
target=android-${api}
EOF
  echo "OK: AVD ${name} (android-${api} ${tag} x86_64) in ${ANDROID_AVD_HOME}"
}

avd_start() {
  local name="$1" serial="emulator-${AVD_PORT}" log t0 adb="${ANDROID_HOME}/platform-tools/adb"
  if [ ! -r "${AVD_KVM_DEVICE}" ] || [ ! -w "${AVD_KVM_DEVICE}" ]; then
    echo "ERROR: ${AVD_KVM_DEVICE} is not usable by uid $(id -u): run the container with --device /dev/kvm and --group-add <the device's gid>" >&2
    return 1
  fi
  [ -f "${ANDROID_AVD_HOME}/${name}.ini" ] || avd_create "${name}"
  log="${ANDROID_AVD_HOME}/${name}.log"
  t0="$(date +%s)"
  nohup "${ANDROID_HOME}/emulator/emulator" -avd "${name}" -port "${AVD_PORT}" -no-window -no-audio \
    -no-boot-anim -no-snapshot -no-metrics -gpu swiftshader_indirect > "${log}" 2>&1 &
  timeout "${AVD_BOOT_TIMEOUT}" "${adb}" -s "${serial}" wait-for-device || true
  until [ "$("${adb}" -s "${serial}" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; do
    if [ $(( $(date +%s) - t0 )) -ge "${AVD_BOOT_TIMEOUT}" ]; then
      echo "ERROR: ${name} did not boot within ${AVD_BOOT_TIMEOUT}s; the emulator log ends:" >&2
      tail -20 "${log}" >&2
      "${adb}" -s "${serial}" emu kill >/dev/null 2>&1 || true
      return 1
    fi
    sleep 3
  done
  echo "OK: ${serial} booted in $(( $(date +%s) - t0 ))s (log: ${log})"
}

avd_stop() {
  "${ANDROID_HOME}/platform-tools/adb" -s "emulator-${AVD_PORT}" emu kill
}

main() {
  local cmd="${1:-}" name="${2:-kataglyphis}"
  case "${cmd}" in
    create) avd_create "${name}" ;;
    start)  avd_start "${name}" ;;
    stop)   avd_stop ;;
    *)      avd_usage ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
