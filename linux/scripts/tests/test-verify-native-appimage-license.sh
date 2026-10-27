#!/usr/bin/env bash
# Exercises the extraction contract with a fixture, not a real AppImage runtime.
set -u
tests_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${tests_dir}/test-harness.sh"
source "${tests_dir}/../01-core/platform.sh"
script="${tests_dir}/../06-packaging/verify-native-appimage-license.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/tmp"
printf 'Original license\n' > "$work/LICENSE"
cat > "$work/appimage" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf called >> "$APPIMAGE_TRACE"
[ "$1" = --appimage-extract ]
[ "$2" = usr/lib/oxidant/LICENSE ]
mkdir -p squashfs-root/usr/lib/oxidant
case "${APPIMAGE_FIXTURE:-good}" in
  good) cp "$EXPECTED_LICENSE" squashfs-root/usr/lib/oxidant/LICENSE ;;
  wrong) printf wrong > squashfs-root/usr/lib/oxidant/LICENSE ;;
  missing) : ;;
  fail) exit 15 ;;
esac
SH
chmod +x "$work/appimage"
export EXPECTED_LICENSE="$work/LICENSE" TMPDIR="$work/tmp" APPIMAGE_TRACE="$work/trace" APPIMAGE_FIXTURE=good
arch="$(arch_normalize "$(uname -m)")"
entry=usr/lib/oxidant/LICENSE
t_case 'extracts and verifies the original license'
t_assert_ok bash "$script" "$work/appimage" "$arch" "$entry" "$work/LICENSE"
t_case 'missing and modified license bytes fail'
for APPIMAGE_FIXTURE in missing wrong fail; do
  export APPIMAGE_FIXTURE
  t_assert_fails bash "$script" "$work/appimage" "$arch" "$entry" "$work/LICENSE"
done
unset APPIMAGE_FIXTURE
t_case 'cross-architecture execution fails closed'
if [ "$arch" = amd64 ]; then other=arm64; else other=amd64; fi
t_assert_fails bash "$script" "$work/appimage" "$other" "$entry" "$work/LICENSE"
t_case 'invalid entries are rejected before running the AppImage'
rm -f "$work/trace"
for invalid in '' /LICENSE usr//LICENSE usr/../LICENSE ./LICENSE usr/./LICENSE usr/LICENSE/ 'C:/LICENSE' 'usr\LICENSE' 'usr/*' 'usr/?' 'usr/[ab]' $'usr/\nLICENSE'; do
  t_assert_fails bash "$script" "$work/appimage" "$arch" "$invalid" "$work/LICENSE"
done
t_assert_ok test ! -e "$work/trace"
t_case 'temporary extraction is removed on success and failure'
t_assert_eq "$(find "$work/tmp" -mindepth 1 -print | wc -l | tr -d ' ')" 0
t_summary
