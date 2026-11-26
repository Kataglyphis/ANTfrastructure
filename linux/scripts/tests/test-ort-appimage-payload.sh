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
# An arm64 host also runs the AMD leg, as an x64 host: a uname shim on PATH is the only thing that changes.
if [ -n "${ORT_PAYLOAD_TEST_AS_X64:-}" ]; then
  mkdir "$work/shim" && printf '#!/bin/sh\necho x86_64\n' > "$work/shim/uname" && chmod +x "$work/shim/uname"
  PATH="$work/shim:$PATH"
fi
case "$(uname -m)" in
  x86_64|amd64) variant=amd; engine=libmigraphx-ep.so ;;
  aarch64|arm64) variant=nvidia; engine=libonnxruntime_providers_cuda.so ;;
  *) echo 'SKIP: GPU AppImages support x64 and arm64 only'; exit 0 ;;
esac
mkdir -p "$work/fixture/usr/lib/engine" "$work/fixture/usr/share/licenses/onnxruntime" "$work/wheels" "$work/ep root/lib"
printf 'int fixture(void) { return 17; }\n' > "$work/fixture.c"
# The plugin module carries ORT's two plugin entry points; the AMD verdict reads them.
printf 'int CreateEpFactories(void) { return 0; }\nint ReleaseEpFactory(void) { return 0; }\n' > "$work/plugin.c"
for name in libonnxruntime.so.1 libonnxruntime_providers_shared.so "$engine"; do
  src="$work/fixture.c"; [ "$name" != libmigraphx-ep.so ] || src="$work/plugin.c"
  cc -shared -fPIC -g "$src" -o "$work/fixture/usr/lib/engine/$name" || exit 1
done
cp "$work/fixture/usr/lib/engine/libmigraphx-ep.so" "$work/ep root/lib/" 2>/dev/null || true
export ORT_AMDGPU_EP_ROOT="$work/ep root"
printf 'license\n' > "$work/fixture/usr/share/licenses/onnxruntime/LICENSE"
printf 'notices\n' > "$work/fixture/usr/share/licenses/onnxruntime/ThirdPartyNotices.txt"
python3 - "$work" <<'PY'
import pathlib
import sys
import zipfile

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
t_case 'finished AppImage binaries and both original texts match one wheel (the AMD plugin module the image copy)'
t_assert_ok check
if [ "$variant" = amd ]; then
  t_assert_contains "$(check)" 'PASS: finished AppImage ORT payload and notices match one GPU wheel (migraphx)'
  t_assert_contains "$(ORT_AMDGPU_EP_ROOT="$work/nowhere" check 2>&1)" "is not the image's" 'a plugin module no image copy vouches for fails'
fi
t_case 'the wheel proof is exact for NVIDIA and after the image strip for AMD, on any host'
t_assert_eq '--require-unstripped --strip strip' "$(STRIP='' source "${_T_SCRIPTS}/06-packaging/ort-package-proof.sh" && ort_wheel_proof_args cuda | paste -sd' ')"
t_assert_eq '--strip strip' "$(STRIP=llvm-strip source "${_T_SCRIPTS}/06-packaging/ort-package-proof.sh" && ort_wheel_proof_args migraphx | paste -sd' ')"
t_case 'a stripped core passes on AMD, whose image strips its CPU core, and fails on NVIDIA'
cp "$work/fixture/usr/lib/engine/libonnxruntime.so.1" "$work/core"
strip --strip-all "$work/fixture/usr/lib/engine/libonnxruntime.so.1"
if [ "$variant" = amd ]; then t_assert_ok check; else t_assert_fails check; fi
cp "$work/core" "$work/fixture/usr/lib/engine/libonnxruntime.so.1"
t_case 'a changed or stripped provider fails even when stripping the wheel would match it'
cp "$work/fixture/usr/lib/engine/${engine}" "$work/provider"
strip --strip-all "$work/fixture/usr/lib/engine/${engine}"
t_assert_fails check
cp "$work/provider" "$work/fixture/usr/lib/engine/${engine}"
printf x >> "$work/fixture/usr/lib/engine/${engine}"
t_assert_fails check
cp "$work/provider" "$work/fixture/usr/lib/engine/${engine}"
t_case 'missing provider, altered notice and unsupported variants fail'
mv "$work/fixture/usr/lib/engine/${engine}" "$work/missing"
t_assert_fails check
ln -s libonnxruntime_providers_shared.so "$work/fixture/usr/lib/engine/${engine}"
t_assert_fails check
rm "$work/fixture/usr/lib/engine/${engine}"
mv "$work/missing" "$work/fixture/usr/lib/engine/${engine}"
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
t_case '--nvidia-core names the bare soname a bundle stages alone; any other name is a usage error'
t_assert_rc 2 bash "$verifier" --nvidia-core libonnxruntime_providers_shared.so "$work/image" "$(uname -m)" usr/lib/engine usr/share/licenses/onnxruntime "$variant"
# An NVIDIA bundle that stages only the bare soname, on any host: the versioned default refuses it, the option accepts it.
mkdir -p "$work/nv/fixture/usr/lib/engine" "$work/nv/fixture/usr/share/licenses/onnxruntime" "$work/nv/wheels"
for name in libonnxruntime.so libonnxruntime_providers_shared.so libonnxruntime_providers_cuda.so; do
  cc -shared -fPIC -g "$work/fixture.c" -o "$work/nv/fixture/usr/lib/engine/$name" || exit 1
done
cp "$work/fixture/usr/share/licenses/onnxruntime/"* "$work/nv/fixture/usr/share/licenses/onnxruntime/"
python3 -c 'import pathlib, sys, zipfile
root = pathlib.Path(sys.argv[1])
with zipfile.ZipFile(root / "wheels/onnxruntime_gpu_fixture-1.whl", "w") as wheel:
    for path in (root / "fixture/usr/lib/engine").iterdir():
        wheel.write(path, "onnxruntime/capi/" + path.name)
    for path in (root / "fixture/usr/share/licenses/onnxruntime").iterdir():
        wheel.write(path, "onnxruntime/" + path.name)' "$work/nv"
nv_opts=()
nv_check() { FIXTURE_ROOT="$work/nv/fixture" ORT_CHAIN_WHEEL_DIR="$work/nv/wheels" bash "$verifier" "${nv_opts[@]}" "$work/image" "$(uname -m)" usr/lib/engine usr/share/licenses/onnxruntime nvidia; }
t_assert_contains "$(nv_check 2>&1)" 'Missing GPU ORT library: libonnxruntime.so.1'
nv_opts=(--nvidia-core libonnxruntime.so)
t_assert_ok nv_check
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
if [ "$variant" = nvidia ] && [ -z "${ORT_PAYLOAD_TEST_AS_X64:-}" ]; then
  t_case 'the AMD leg passes on this arm64 host too, run as x64'
  t_assert_ok env ORT_PAYLOAD_TEST_AS_X64=1 bash "${BASH_SOURCE[0]}"
fi
t_summary
