#!/usr/bin/env bash
# Synthetic archives prove original-text transport and failures, not source authentication, full licences or a GCC build.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
GCC="${1:-${TESTS_DIR}/../02-toolchain/build-gcc.sh}"
WORK="$(mktemp -d)"
trap 'rm -rf -- "${WORK}"' EXIT
for helper in _gcc_notice_required_file _gcc_notice_output_path _gcc_stage_runtime_notices; do
  t_fn_src "${GCC}" "${helper}" >> "${WORK}/helper.sh" || exit 1
done
awk '$1 == "_gcc_stage_runtime_notices" {print; found++} END {if (found != 1) exit 1}' \
  "${GCC}" > "${WORK}/entry.sh" || exit 1
printf '\nprintf AFTER_NOTICE\n' >> "${WORK}/entry.sh"

notice_fixture() {
  local root="$1"
  mkdir -p "${root}/build/gcc-1.2.3" "${root}/prefix"
  printf 'Original GPL text\r\n\377\n' > "${root}/build/gcc-1.2.3/COPYING3"
  printf 'Original runtime exception\n' > "${root}/build/gcc-1.2.3/COPYING.RUNTIME"
  tar -C "${root}/build" -cJf "${root}/build/gcc-1.2.3.tar.xz" gcc-1.2.3 || return $?
  return 0
}

notice_run() {
  local root="$1" failure="${2:-none}" entry="${3:-conditional}"
  bash -euo pipefail -c '
    source "$1/helper.sh"
    BUILD_DIR="$2/build" PREFIX="$2/prefix" GCC_VERSION=1.2.3 SUDO=
    TARBALL=gcc-1.2.3.tar.xz TARBALL_URL=https://example.invalid/gcc-1.2.3.tar.xz
    fixture_failure="$3"
    install() {
      if [ "$fixture_failure" = install ] && [ "$1" = -m ]; then return 47; fi
      command install "$@"
    }
    sha512sum() {
      if [ "$fixture_failure" = hash ]; then return 41; fi
      command sha512sum "$@"
    }
    tar() {
      if [ "$fixture_failure" = archive ]; then return 42; fi
      command tar "$@"
    }
    tee() {
      if [ "$fixture_failure" = metadata ] && [ "${2##*/}" = source.sha512 ]; then return 43; fi
      if [ "$fixture_failure" = metadata-url ] && [ "${2##*/}" = source.url ]; then return 44; fi
      command tee "$@"
    }
    if [ "$4" = entry ]; then
      if source "$1/entry.sh"; then printf CLEANUP; else exit "$?"; fi
    elif _gcc_stage_runtime_notices; then
      exit 0
    else
      exit "$?"
    fi
  ' _ "${WORK}" "${root}" "${failure}" "${entry}"
}

t_case 'both original notices and source pointers survive at an installed prefix with spaces'
root="${WORK}/valid with spaces"$'\n'"and\\backslash"
notice_fixture "${root}" || exit 1
t_assert_ok notice_run "${root}"
destination="${root}/prefix/share/licenses/gcc-runtime"
for notice in COPYING3 COPYING.RUNTIME; do
  t_assert_ok cmp "${root}/build/gcc-1.2.3/${notice}" "${destination}/${notice}"
  t_assert_eq 644 "$(stat -c %a "${destination}/${notice}")"
done
checksum="$(sha512sum < "${root}/build/gcc-1.2.3.tar.xz")"
t_assert_eq "${checksum%% *}  gcc-1.2.3.tar.xz" "$(cat "${destination}/source.sha512")"
t_assert_eq https://example.invalid/gcc-1.2.3.tar.xz "$(cat "${destination}/source.url")"
t_assert_ok notice_run "${root}"
rm -rf -- "${root}/build"
for notice in COPYING3 COPYING.RUNTIME; do t_assert_ok test -s "${destination}/${notice}"; done

t_case 'a missing, empty, linked or archive-mismatched notice refuses before publication'
for variant in missing empty original-empty linked changed; do
  root="${WORK}/${variant}"
  notice_fixture "${root}" || exit 1
  notice="${root}/build/gcc-1.2.3/COPYING.RUNTIME"
  case "${variant}" in
    missing) rm -- "${notice}" ;;
    empty) : > "${notice}" ;;
    original-empty)
      : > "${notice}"
      tar -C "${root}/build" -cJf "${root}/build/gcc-1.2.3.tar.xz" gcc-1.2.3 || exit 1 ;;
    linked) mv "${notice}" "${root}/original"; ln -s "${root}/original" "${notice}" ;;
    changed) printf 'rewritten terms\n' > "${notice}" ;;
  esac
  t_assert_fails notice_run "${root}"
  t_assert_ok test ! -e "${root}/prefix/share/licenses/gcc-runtime"
done

t_case 'a linked source archive and linked notice destination or output refuse'
for variant in archive destination output; do
  root="${WORK}/linked-${variant}"
  notice_fixture "${root}" || exit 1
  case "${variant}" in
    archive)
      mv "${root}/build/gcc-1.2.3.tar.xz" "${root}/original.tar.xz"
      ln -s "${root}/original.tar.xz" "${root}/build/gcc-1.2.3.tar.xz" ;;
    destination)
      mkdir -p "${root}/prefix/share/licenses" "${root}/outside"
      ln -s "${root}/outside" "${root}/prefix/share/licenses/gcc-runtime" ;;
    output)
      mkdir -p "${root}/prefix/share/licenses/gcc-runtime"
      printf 'preserved\n' > "${root}/outside"
      ln -s "${root}/outside" "${root}/prefix/share/licenses/gcc-runtime/COPYING3" ;;
  esac
  t_assert_fails notice_run "${root}"
  if [ "${variant}" = output ]; then t_assert_eq preserved "$(cat "${root}/outside")"; fi
done

t_case 'raw archive, hashing, installation and metadata failures survive conditional callers'
for pair in archive:42 hash:41 install:47 metadata:43 metadata-url:44; do
  root="${WORK}/failure-${pair%:*}"
  notice_fixture "${root}" || exit 1
  rc=0
  notice_run "${root}" "${pair%:*}" > "${WORK}/out" 2>&1 || rc=$?
  t_assert_eq "${pair#*:}" "${rc}"
done

t_case 'the actual builder entry aborts before cleanup when staging fails'
root="${WORK}/entry-failure"
notice_fixture "${root}" || exit 1
rc=0
notice_run "${root}" install entry > "${WORK}/out" 2>&1 || rc=$?
t_assert_eq 47 "${rc}"
t_assert_eq '' "$(cat "${WORK}/out")"
t_summary
