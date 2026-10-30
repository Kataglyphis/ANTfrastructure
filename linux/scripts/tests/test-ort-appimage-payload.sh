#!/usr/bin/env bash
# Verifies finished AppImage GPU ORT payloads, including stripped and changed files.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
verifier="${_T_SCRIPTS}/06-packaging/verify-ort-appimage-payload.sh"
t_skip_unless 'C compiler' command -v cc
t_skip_unless 'strip' command -v strip
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
case "$(uname -m)" in
  x86_64|amd64) variant=amd; provider=migraphx ;;
  aarch64|arm64) variant=nvidia; provider=cuda ;;
  *) echo 'SKIP: GPU AppImages support x64 and arm64 only'; exit 0 ;;
esac
mkdir -p "$work/fixture/usr/lib/engine" "$work/fixture/usr/share/licenses/onnxruntime" "$work/wheels"
printf 'int fixture(void) { return 17; }\n' > "$work/fixture.c"
for name in libonnxruntime.so.1 libonnxruntime_providers_shared.so "libonnxruntime_providers_${provider}.so"; do
  cc -shared -fPIC -g "$work/fixture.c" -o "$work/fixture/usr/lib/engine/$name" || exit 1
done
printf 'license\n' > "$work/fixture/usr/share/licenses/onnxruntime/LICENSE"
printf 'notices\n' > "$work/fixture/usr/share/licenses/onnxruntime/ThirdPartyNotices.txt"
python3 - "$work" <<'PY'
import pathlib, sys, zipfile
root = pathlib.Path(sys.argv[1])
bundle = root / 'fixture/usr'
with zipfile.ZipFile(root / 'wheels/onnxruntime_fixture-1.whl', 'w') as wheel:
    for path in (bundle / 'lib/engine').iterdir():
        wheel.write(path, 'onnxruntime/capi/' + path.name)
    for path in (bundle / 'share/licenses/onnxruntime').iterdir():
        wheel.write(path, 'onnxruntime/' + path.name)
PY
cat > "$work/image" <<'IMAGE'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = --appimage-extract ]
[ "$#" = 1 ]
mkdir -p squashfs-root
cp -a "$FIXTURE_ROOT/." squashfs-root/
IMAGE
chmod +x "$work/image"
export FIXTURE_ROOT="$work/fixture" ORT_CHAIN_WHEEL_DIR="$work/wheels"
check() { bash "$verifier" "$work/image" "$(uname -m)" usr/lib/engine usr/share/licenses/onnxruntime "$variant"; }
t_case 'finished AppImage binaries and both original texts match one wheel'
t_assert_ok check
t_case 'a changed or stripped provider fails even when stripping the wheel would match it'
cp "$work/fixture/usr/lib/engine/libonnxruntime_providers_${provider}.so" "$work/provider"
strip --strip-all "$work/fixture/usr/lib/engine/libonnxruntime_providers_${provider}.so"
t_assert_fails check
cp "$work/provider" "$work/fixture/usr/lib/engine/libonnxruntime_providers_${provider}.so"
printf x >> "$work/fixture/usr/lib/engine/libonnxruntime_providers_${provider}.so"
t_assert_fails check
cp "$work/provider" "$work/fixture/usr/lib/engine/libonnxruntime_providers_${provider}.so"
t_case 'missing provider, altered notice and unsupported variants fail'
mv "$work/fixture/usr/lib/engine/libonnxruntime_providers_${provider}.so" "$work/missing"
t_assert_fails check
ln -s libonnxruntime_providers_shared.so "$work/fixture/usr/lib/engine/libonnxruntime_providers_${provider}.so"
t_assert_fails check
rm "$work/fixture/usr/lib/engine/libonnxruntime_providers_${provider}.so"
mv "$work/missing" "$work/fixture/usr/lib/engine/libonnxruntime_providers_${provider}.so"
t_case 'a versioned core symlink works, but a core alias to a provider fails'
cp "$work/fixture/usr/lib/engine/libonnxruntime.so.1" "$work/fixture/usr/lib/engine/libonnxruntime.so.1.2.3"
rm "$work/fixture/usr/lib/engine/libonnxruntime.so.1"
ln -s libonnxruntime.so.1.2.3 "$work/fixture/usr/lib/engine/libonnxruntime.so.1"
t_assert_ok check
rm "$work/fixture/usr/lib/engine/libonnxruntime.so.1"
ln -s libonnxruntime_providers_shared.so "$work/fixture/usr/lib/engine/libonnxruntime.so.1"
t_assert_fails check
rm "$work/fixture/usr/lib/engine/libonnxruntime.so.1"
mv "$work/fixture/usr/lib/engine/libonnxruntime.so.1.2.3" "$work/fixture/usr/lib/engine/libonnxruntime.so.1"
t_case 'altered notices and unsupported variants fail'
printf wrong > "$work/fixture/usr/share/licenses/onnxruntime/LICENSE"
t_assert_fails check
t_assert_fails bash "$verifier" "$work/image" "$(uname -m)" usr/lib/engine usr/share/licenses/onnxruntime invalid
t_assert_fails bash "$verifier" "$work/image" "$(uname -m)" ../escape usr/share/licenses/onnxruntime "$variant"
t_case 'a host SDK file or symlink anywhere in the final AppImage is rejected'
printf 'license\n' > "$work/fixture/usr/share/licenses/onnxruntime/LICENSE"
mkdir -p "$work/fixture/opt/other"
if [[ "$variant" == amd ]]; then sdk=libhsa-runtime64.so.1; else sdk=libcudart.so.13; fi
printf sdk > "$work/fixture/opt/other/$sdk"
t_assert_fails check
rm "$work/fixture/opt/other/$sdk"
ln -s ../missing "$work/fixture/opt/other/$sdk"
t_assert_fails check
t_summary
