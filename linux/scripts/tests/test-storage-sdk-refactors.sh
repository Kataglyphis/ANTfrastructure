#!/usr/bin/env bash
# Admission ordering and SDK archive layout are covered without containers, apt or network access.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
source "${TESTS_DIR}/../01-core/chain-storage.sh"
log() { printf '%s\n' "$*"; }
warn() { log "$@"; }
err() { log "$@"; exit 1; }
arch_list_to_words() { printf 'amd64 arm64\n'; }
stage_enabled() { return 1; }
_chain_runtime_lane_need_gb() { printf '120'; }
is_dry_run() { [ "${DRY_RUN:-0}" = 1 ] && return 0; return 1; }
_disk_guard_free_gb() {
  : "${BEFORE:=20}"
  if [ -f "${WORK}/trimmed" ]; then printf '%s' "${AFTER:-150}"; else printf '%s' "${BEFORE:-20}"; fi
}
_disk_guard_trim_cache_export() { touch "${WORK}/trimmed"; }
_preflight() {
  (
    export BUILDKIT_CACHE_DIR="${WORK}/cache"
    export TARGET_ARCHES=amd64,arm64
    export FROM_STAGE=sdk
    _chain_disk_preflight
  )
}
mkdir -p "${WORK}/cache"
t_case "forced low disk returns before trimming"
t_assert_contains "$(FORCE_LOW_DISK=1 _preflight)" 'continuing on the warm cache'
t_assert_eq no "$(test -e "${WORK}/trimmed" && echo yes || echo no)"
t_case "dry run returns before trimming"
t_assert_contains "$(DRY_RUN=1 _preflight)" '[DRY RUN]'
t_assert_eq no "$(test -e "${WORK}/trimmed" && echo yes || echo no)"
t_case "disabled preflight performs no trim"
t_assert_eq '' "$(DISK_PREFLIGHT=0 _preflight)"
t_case "disabled trimming leaves a hard admission failure"
t_assert_eq 1 "$(CROSS_PREFLIGHT_TRIM=0 _preflight >/dev/null; echo $?)"
t_assert_eq no "$(test -e "${WORK}/trimmed" && echo yes || echo no)"
t_case "successful trimming remeasures space before admission"
t_assert_contains "$(_preflight)" 'disk preflight OK after trim: 150G'
t_assert_eq yes "$(test -e "${WORK}/trimmed" && echo yes || echo no)"
rm -f "${WORK}/trimmed"
t_case "insufficient space after trimming remains fatal"
t_assert_eq 1 "$(AFTER=30 _preflight >/dev/null; echo $?)"
rm -f "${WORK}/trimmed"
source "${TESTS_DIR}/../02-toolchain/vulkan-install.sh"
install_vulkan_prereqs() { :; }
arch_normalize() { printf '%s' "$1"; }
arch_uname_name_for() { printf '%s' "${SDK_ARCH:-x86_64}"; }
arch_deb_multiarch_triplet_for() { printf 'fixture-triplet'; }
die() { printf '%s\n' "$*" >&2; exit 1; }
chown() { :; }
_build_vulkan_sdk_cross() { printf '%s\n' "$*" > "${WORK}/cross-args"; }
download_verified_file() {
  printf 'verified %s\n' "$2" > "${WORK}/download-mode"
  cp "${WORK}/archive.tar.xz" "$3"
}
download_file() {
  printf 'unverified %s %s\n' "$3" "$4" > "${WORK}/download-mode"
  cp "${WORK}/archive.tar.xz" "$2"
}
_sdk_install() {
  (
    cd "${WORK}/download" || exit 1
    export VULKAN_INSTALL_ROOT="${WORK}/installed"
    export VULKAN_TMP_DIR="${WORK}/tmp"
    export TARGET_ARCH=amd64
    export SUDO=''
    install_vulkan_sdk fixture >/dev/null
  )
}
mkdir -p "${WORK}/download" "${WORK}/payload/sdk/bin"
printf 'compiler\n' > "${WORK}/payload/sdk/bin/glslc"
tar -cJf "${WORK}/archive.tar.xz" -C "${WORK}/payload" sdk
t_case "single-root SDK archive loses its outer directory"
VULKAN_SDK_SHA256=fixture-sha _sdk_install
t_assert_eq compiler "$(cat "${WORK}/installed/fixture/bin/glslc")"
t_assert_eq 'verified fixture-sha' "$(cat "${WORK}/download-mode")"
t_assert_eq no "$(test -e "${WORK}/cross-args" && echo yes || echo no)"
t_assert_eq 0 "$(find "${WORK}/tmp" -mindepth 1 -maxdepth 1 | wc -l)"
mkdir -p "${WORK}/payload/sdk/include"
printf 'header\n' > "${WORK}/payload/sdk/include/vulkan.h"
tar -cJf "${WORK}/archive.tar.xz" -C "${WORK}/payload/sdk" bin include
t_case "flat SDK archive preserves each root and builds foreign targets"
VULKAN_SDK_SHA256='' SDK_ARCH=aarch64 _sdk_install
t_assert_eq header "$(cat "${WORK}/installed/fixture/include/vulkan.h")"
t_assert_eq 'unverified 3 30' "$(cat "${WORK}/download-mode")"
t_assert_contains "$(cat "${WORK}/cross-args")" "aarch64 ${WORK}/installed/fixture fixture-triplet"
t_case "download failures cannot reach archive extraction"
cp "${WORK}/archive.tar.xz" "${WORK}/download/vulkansdk-linux-x86_64-fixture.tar.xz"
t_assert_eq 1 "$(download_verified_file() { return 7; }; VULKAN_SDK_SHA256=fixture _sdk_install 2>/dev/null; echo $?)"
t_assert_eq 1 "$(download_file() { return 7; }; VULKAN_SDK_SHA256='' _sdk_install 2>/dev/null; echo $?)"
t_case "SDK driver loads the provisioning library in the real source layout"
t_assert_eq function "$(bash -c 'download_file() { :; }; source "$1"; type -t install_vulkan_sdk' _ "${TESTS_DIR}/../02-toolchain/vulkan.sh")"
t_assert_contains "$(cat "${TESTS_DIR}/../../Dockerfile.sdk")" 'linux/scripts/02-toolchain/vulkan-install.sh'
t_summary
