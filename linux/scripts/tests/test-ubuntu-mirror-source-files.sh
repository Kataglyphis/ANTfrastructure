#!/usr/bin/env bash
# Extracted caller operations cover source-file enumeration and shell options using local paths, without running apt or mirror rewrites.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
BASE="${1:-${TESTS_DIR}/../01-core/base-image.sh}"
FAST="${2:-${TESTS_DIR}/../01-core/use-fast-ubuntu-mirror.sh}"
OWNER="${3:-${TESTS_DIR}/../01-core/ubuntu-mirror.sh}"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/populated/etc/apt/sources.list.d/subdir.list" "${WORK}/empty/etc/apt/sources.list.d"
touch "${WORK}/populated/etc/apt/sources.list.d/a list.list" "${WORK}/populated/etc/apt/sources.list.d/z.list" \
  "${WORK}/populated/etc/apt/sources.list.d/a.sources" "${WORK}/populated/etc/apt/sources.list.d/.hidden.list" \
  "${WORK}/populated/etc/apt/sources.list.d/ignored.conf"
ln -s absent "${WORK}/populated/etc/apt/sources.list.d/broken.sources"
cp -a "${WORK}/populated" "${WORK}/populated with spaces"
cat > "${WORK}/worker.sh" <<'BASH'
set -euo pipefail
source "$1"
source "$2"
operation="$3"; root="$4"; mode="$5"; cd "$6"
case "$mode" in
  incoming-nullglob) shopt -s nullglob ;;
  dotglob) shopt -s dotglob ;;
  noglob) set -f ;;
  failglob) shopt -s failglob ;;
esac
files=(stale)
collect() {
  local -n source_files="$1"
  local sources_root="$2"
  source "$operation"
}
collect files "$root"
if shopt -q nullglob; then printf 'NULLGLOB=on\n'; else printf 'NULLGLOB=off\n'; fi
case "$-" in *f*) printf 'NOGLOB=on\n' ;; *) printf 'NOGLOB=off\n' ;; esac
if shopt -q dotglob; then printf 'DOTGLOB=on\n'; else printf 'DOTGLOB=off\n'; fi
printf 'FILE=%q\n' "${files[@]}"
BASH

for caller in "${BASE}" "${FAST}"; do
  awk '/^  ubuntu_mirror_source_files source_files / { print; exit } /^  shopt -s nullglob$/ { printing=1 } printing { print } printing && /^  shopt -u nullglob$/ { exit }' "${caller}" > "${WORK}/operation.sh"
  [ -s "${WORK}/operation.sh" ] || { printf 'missing enumeration operation in %s\n' "${caller}" >&2; exit 1; }
  for mode in populated empty missing incoming-nullglob dotglob noglob relative trailing spaces failglob; do
    t_case "${caller##*/} source files ${mode}"
    root="${WORK}/populated"; prefix="${WORK}/populated/"
    case "$mode" in
      empty|failglob) root="${WORK}/empty"; prefix="${WORK}/empty/" ;;
      missing) root="${WORK}/missing"; prefix="${WORK}/missing/" ;;
      relative) root=populated; prefix=populated/ ;;
      spaces) root="${WORK}/populated with spaces"; prefix="${root}/" ;;
      trailing) root="${WORK}/populated///"; prefix="${WORK}/populated///" ;;
    esac
    rc=0
    out="$(LC_ALL=C timeout 5 bash "${WORK}/worker.sh" "${TESTS_DIR}/../01-core/platform.sh" "${OWNER}" "${WORK}/operation.sh" "${root}" "${mode}" "${WORK}" 2> "${WORK}/err")" || rc=$?
    if [ "${mode}" = failglob ]; then
      t_assert_eq 1 "${rc}"
      t_assert_eq '' "${out}"
      t_assert_contains "$(cat "${WORK}/err")" 'no match'
      continue
    fi
    t_assert_eq 0 "${rc}"
    t_assert_eq '' "$(cat "${WORK}/err")"
    expected_files=("${prefix}etc/apt/sources.list")
    case "$mode" in
      empty|missing) : ;;
      noglob) expected_files+=("${prefix}etc/apt/sources.list.d/*.list" "${prefix}etc/apt/sources.list.d/*.sources") ;;
      *)
        if [ "${mode}" = dotglob ]; then expected_files+=("${prefix}etc/apt/sources.list.d/.hidden.list"); fi
        expected_files+=("${prefix}etc/apt/sources.list.d/a list.list" "${prefix}etc/apt/sources.list.d/subdir.list" "${prefix}etc/apt/sources.list.d/z.list" \
          "${prefix}etc/apt/sources.list.d/a.sources" "${prefix}etc/apt/sources.list.d/broken.sources") ;;
    esac
    expected=$'NULLGLOB=off\nNOGLOB=off\nDOTGLOB=off'
    if [ "${mode}" = noglob ]; then expected=$'NULLGLOB=off\nNOGLOB=on\nDOTGLOB=off'; fi
    if [ "${mode}" = dotglob ]; then expected=$'NULLGLOB=off\nNOGLOB=off\nDOTGLOB=on'; fi
    expected+=$'\n'"$(printf 'FILE=%q\n' "${expected_files[@]}")"
    t_assert_eq "${expected}" "${out}" 'both callers preserve literal path, glob groups, ordering and shell-option policy'
  done
done
t_summary
