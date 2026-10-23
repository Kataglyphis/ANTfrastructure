#!/usr/bin/env bash
# Stubbed install tails cover optional strip dispatch and ordering, not real prefix stripping or framework builds.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
COMMON="${1:-${TESTS_DIR}/../03-media/core/common.sh}"
ARMNN="${2:-${TESTS_DIR}/../03-media/build/armnn/build-armnn.sh}"
OPENCV="${3:-${TESTS_DIR}/../03-media/build/opencv/build-opencv.sh}"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
t_fn_src "${ARMNN}" build_armnn > "${work}/armnn.sh" || exit 1
t_fn_src "${OPENCV}" main > "${work}/opencv.sh" || exit 1
mkdir -p "${work}/bin"
printf '#!/bin/sh\necho external-strip >> "$STRIP_EVENTS"\n' > "${work}/bin/strip_media_prefixes"
chmod +x "${work}/bin/strip_media_prefixes"
cat > "${work}/worker" <<'WORKER'
set -euo pipefail
source "$1"
source "$2/$3.sh"
root="$2" runtime="$3" mode="$4"
export STRIP_EVENTS="$root/events"
export PATH="$root/bin:$PATH"
unset -f strip_media_prefixes 2>/dev/null || true
if [ "$mode" != absent ]; then
  strip_media_prefixes() {
    printf 'strip:<%s>\n' "$@" >> "$STRIP_EVENTS"
    if [ "$mode" = failing ]; then return 7; fi
  }
fi
info() { printf 'INFO:%s\n' "$*"; }
die() { printf 'ERROR:%s\n' "$*" >&2; exit 87; }
ls() { printf 'list:<%s>\n' "$@" >> "$STRIP_EVENTS"; printf 'library listing\n'; }
if [ "$runtime" = armnn ]; then
  ARCH=arm64 BUILD_MODE=native
  ARMNN_BUILD_DIR="$root/build" ARMNN_SRC_DIR="$root/source"
  ARMNN_INSTALL_DIR="$root/arm nn" ACL_INSTALL_DIR="$root/acl"
  _armnn_link_openmp() { :; }
  media_jobs() { printf 2; }
  cmake() {
    case "$1" in --install) printf 'installed\n' >> "$STRIP_EVENTS" ;; esac
  }
  build_armnn
else
  FORCE_REBUILD=1 WITH_PYTHON=false
  OPENCV_PREFIX="$root/open cv" OPENCV_SRC="$root/source"
  OPENCV_ORT_CHAIN_ROOT="$root/ort" OPENCV_VERSION=fixture
  fetch_opencv() { :; }
  configure_opencv() { :; }
  build_opencv() { :; }
  install_opencv() { printf 'installed\n' >> "$STRIP_EVENTS"; }
  ort_assert_chain_only() { printf 'provenance\n' >> "$STRIP_EVENTS"; }
  cleanup() { printf 'cleanup\n' >> "$STRIP_EVENTS"; }
  pkg-config() { if [ "$1" = --modversion ]; then printf fixture; fi; }
  main
fi
printf 'completed\n'
WORKER

output='' status=0
for runtime in armnn opencv; do
  prefix="${work}/arm nn"
  install_events=installed
  [ "${runtime}" != opencv ] || { prefix="${work}/open cv"; install_events=$'installed\nprovenance\ncleanup'; }
  for mode in absent present failing; do
    t_case "${runtime}: ${mode} strip remains best-effort after install and before listing"
    : > "${work}/events"
    t_capture_command output status bash "${work}/worker" "${COMMON}" "${work}" "${runtime}" "${mode}"
    t_assert_eq 0 "${status}" "${output}"
    t_assert_contains "${output}" completed
    expected="${install_events}"
    [ "${mode}" = absent ] || expected+=$'\n'"strip:<${prefix}>"
    library="${prefix}/lib"
    [ "${runtime}" != armnn ] || library+=/
    expected+=$'\n'"list:<-la>"$'\n'"list:<${library}>"
    t_assert_eq "${expected}" "$(cat "${work}/events")" "keep argv, optional command policy and ordering"
    t_assert_contains "${output}" 'library listing'
  done
done
t_summary
