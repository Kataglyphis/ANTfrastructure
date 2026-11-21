#!/usr/bin/env bash
# Controlled extraction tests selected file verdicts and cleanup, not actual AppImage execution or source provenance.
set -u
tests_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$tests_dir/test-harness.sh"
source "$tests_dir/../01-core/platform.sh"
kind="$1"
script="$tests_dir/../06-packaging/verify-native-appimage-$kind.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/tmp"
if [ "$kind" = binary ]; then
  printf '\177ELF\r\n\000\377original\r\n' > "$work/input"
else
  printf 'Original license\n' > "$work/input"
fi
cp "$tests_dir/fixtures/appimage-selected-file.sh" "$work/appimage"
chmod +x "$work/appimage"
export EXPECTED_FILE="$work/input" EXPECTED_ENTRY='usr/lib/app space/selected-file'
export TMPDIR="$work/tmp" APPIMAGE_TRACE="$work/trace" APPIMAGE_FIXTURE=good
arch="$(arch_normalize "$(uname -m)")"
t_case 'the native reader verifies original bytes through a spaced selected path'
t_assert_ok bash "$script" "$work/appimage" "$arch" "$EXPECTED_ENTRY" "$EXPECTED_FILE"
t_case 'missing, modified, linked and failed extraction cannot satisfy the selected-file proof'
for APPIMAGE_FIXTURE in missing wrong symlink fail rootlink; do
  export APPIMAGE_FIXTURE
  t_assert_fails bash "$script" "$work/appimage" "$arch" "$EXPECTED_ENTRY" "$EXPECTED_FILE"
done
t_case 'the native extraction failure preserves its raw status'
actual=0
APPIMAGE_FIXTURE=fail bash "$script" "$work/appimage" "$arch" "$EXPECTED_ENTRY" "$EXPECTED_FILE" >/dev/null 2>&1 || actual=$?
t_assert_eq 15 "$actual"
unset APPIMAGE_FIXTURE
if [ "$kind" = binary ]; then
  t_case 'text normalization cannot excuse different binary bytes'
  printf '\177ELF\n\000\377original\n' > "$work/normalized"
  t_assert_fails bash "$script" "$work/appimage" "$arch" "$EXPECTED_ENTRY" "$work/normalized"
fi
t_case 'native architecture and selected-path checks run before extraction'
if [ "$arch" = amd64 ]; then other=arm64; else other=amd64; fi
t_assert_fails bash "$script" "$work/appimage" "$other" "$EXPECTED_ENTRY" "$EXPECTED_FILE"
rm -f "$work/trace"
for invalid in '' /helper usr//helper usr/../helper ./helper usr/./helper usr/helper/ 'usr/*' 'usr/?' 'usr/[ab]' 'C:/helper' 'usr\helper' $'usr/\nhelper'; do
  t_assert_fails bash "$script" "$work/appimage" "$arch" "$invalid" "$EXPECTED_FILE"
done
t_assert_ok test ! -e "$work/trace"
t_case 'native-reader cleanup leaves no temporary extraction roots'
t_assert_eq 0 "$(find "$work/tmp" -mindepth 1 -print | wc -l | tr -d ' ')"
t_summary
