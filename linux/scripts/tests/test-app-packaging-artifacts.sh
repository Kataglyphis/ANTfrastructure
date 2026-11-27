#!/usr/bin/env bash
# Real directory fixtures check the one-artifact selection; not covered: whether the selected package is valid or complete.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
LIB="${1:-${TESTS_DIR}/../lib/app-packaging-artifacts.sh}"
# shellcheck source=../lib/app-packaging-artifacts.sh
source "$LIB"
work="$(t_mktemp -d)"

# Usage: package_dir NAME FILE...; prints a fresh package directory holding the named empty files.
package_dir() {
  local dir="${work}/$1" file
  shift
  mkdir -p "$dir"
  for file in "$@"; do : > "${dir}/${file}"; done
  printf '%s\n' "$dir"
}

for suffix in .deb .tar.gz .AppImage; do
  t_case "exactly one *${suffix} is printed; none and two refuse with the count"
  one="$(package_dir "one-${suffix#.}" "app${suffix}" "app${suffix}.sha256" README)"
  t_assert_eq "${one}/app${suffix}" "$(app_packaging_single_artifact "$one" "$suffix")"
  none="$(package_dir "none-${suffix#.}" README)"
  t_assert_fails app_packaging_single_artifact "$none" "$suffix"
  t_assert_contains "$(t_out app_packaging_single_artifact "$none" "$suffix")" "expected exactly one regular *${suffix} file in ${none}, found 0 match(es)"
  two="$(package_dir "two-${suffix#.}" "app${suffix}" "old${suffix}")"
  t_assert_fails app_packaging_single_artifact "$two" "$suffix"
  t_assert_contains "$(t_out app_packaging_single_artifact "$two" "$suffix")" "found 2 match(es)"
done

t_case 'a directory path with spaces works under the caller IFS'
spaced="$(package_dir 'with space' 'my app.deb')"
t_assert_eq "${spaced}/my app.deb" "$(IFS=$'\n\t'; app_packaging_single_artifact "$spaced" .deb)"

t_case 'a missing directory and a matching non-file refuse'
t_assert_fails app_packaging_single_artifact "${work}/absent" .deb
t_assert_contains "$(t_out app_packaging_single_artifact "${work}/absent" .deb)" "file in ${work}/absent, found 0 match(es)"
nonfile="$(package_dir nonfile)"
mkdir "${nonfile}/app.deb"
t_assert_contains "$(t_out app_packaging_single_artifact "$nonfile" .deb)" "regular *.deb file in ${nonfile}, found 1 match(es)"

t_case 'the caller glob options are kept, and nullglob selects the same artifact'
t_assert_eq off "$(app_packaging_single_artifact "$none" .AppImage 2>/dev/null; shopt -q nullglob && echo on || echo off)"
t_assert_eq "on ${one}/app.AppImage" "$(shopt -s nullglob; found="$(app_packaging_single_artifact "$one" .AppImage)"; shopt -q nullglob && echo "on ${found}")"
t_assert_fails bash -c 'shopt -s nullglob; source "$1"; app_packaging_single_artifact "$2" .AppImage' _ "$LIB" "$none"

t_case 'the three Linux formats are set together'
set_dir="$(package_dir set app.deb app.tar.gz app.AppImage)"
deb='' tarball='' appimage=''
t_assert_ok app_packaging_linux_artifacts "$set_dir" deb tarball appimage
t_assert_eq "${set_dir}/app.deb|${set_dir}/app.tar.gz|${set_dir}/app.AppImage" "${deb}|${tarball}|${appimage}"

t_case 'every miscounted format is reported, and nothing is set'
bad_dir="$(package_dir bad app.tar.gz app.AppImage new.AppImage)"
deb=unset tarball=unset appimage=unset
t_assert_fails app_packaging_linux_artifacts "$bad_dir" deb tarball appimage
report="$(t_out app_packaging_linux_artifacts "$bad_dir" deb tarball appimage)"
t_assert_contains "$report" "*.deb file in ${bad_dir}, found 0 match(es)"
t_assert_contains "$report" "*.AppImage file in ${bad_dir}, found 2 match(es)"
t_assert_eq 'unset|unset|unset' "${deb}|${tarball}|${appimage}"

t_case 'a linked artifact refuses'
t_needs 'real POSIX symlinks for the linked artifact fixture' t_posix_symlinks
linked="$(package_dir linked)"
: > "${work}/outside.deb"
ln -s "${work}/outside.deb" "${linked}/app.deb"
t_assert_contains "$(t_out app_packaging_single_artifact "$linked" .deb)" "regular *.deb file in ${linked}, found 1 match(es)"

t_summary
