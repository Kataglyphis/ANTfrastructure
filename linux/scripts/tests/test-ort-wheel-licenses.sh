#!/usr/bin/env bash
# Tests native ELF-to-wheel matching; it does not audit other shipped dependencies.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
source "${_T_SCRIPTS}/lib/pe-icon-tools.sh"
SCRIPT="${_T_SCRIPTS}/06-packaging/stage-ort-wheel-licenses.py"
source "${_T_SCRIPTS}/06-packaging/ort-wheel-licenses.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
t_skip_unless 'C compiler' command -v cc
t_skip_unless 'strip' command -v strip
foreign_clang="$(pe_icon_find_clang || true)"
foreign_linker="$(pe_icon_find_tool ld.lld || true)"
t_skip_unless 'clang' test -x "$foreign_clang"
t_skip_unless 'lld' test -x "$foreign_linker"
mkdir -p "$work/build" "$work/native" "$work/bundles"
printf '#ifndef VALUE\n#define VALUE 17\n#endif\nint ort_fixture(void) { return VALUE; }\n' > "$work/build/fixture.c"
cc -shared -fPIC -g "$work/build/fixture.c" -o "$work/build/libonnxruntime.so.1.2.3" || exit 1
cc -shared -fPIC -g -DPROVIDER "$work/build/fixture.c" -o "$work/build/libonnxruntime_providers_shared.so" || exit 1
cc -shared -fPIC -g -DVALUE=99 "$work/build/fixture.c" -o "$work/build/wrong-provider.so" || exit 1
case "$(uname -m)" in x86_64|amd64) foreign_target=aarch64-linux-gnu ;; *) foreign_target=x86_64-linux-gnu ;; esac
"$foreign_clang" --target="$foreign_target" -fuse-ld="$foreign_linker" -nostdlib -shared -g "$work/build/fixture.c" -o "$work/build/foreign.so" || exit 1
cp "$work/build/libonnxruntime.so.1.2.3" "$work/build/libonnxruntime_providers_shared.so" "$work/native/"
strip --strip-all "$work/native/"*.so* || exit 1
printf 'original license\nwith second line\n' > "$work/LICENSE"
printf 'third party notices\n' > "$work/ThirdPartyNotices.txt"

python3 - "$work" <<'PY'
import pathlib
import sys
import zipfile

root = pathlib.Path(sys.argv[1])
names = ["libonnxruntime.so.1.2.3", "libonnxruntime_providers_shared.so"]


def make_wheel(case, *, blank=False, missing=False, duplicate="", wrong=False):
    directory = root / case
    directory.mkdir(exist_ok=True)
    with zipfile.ZipFile(directory / "onnxruntime-1-cp315-linux.whl", "w") as wheel:
        for name in names:
            data = (root / "build" / name).read_bytes()
            if wrong and "providers" in name:
                data = (root / "build" / "wrong-provider.so").read_bytes()
            wheel.writestr("onnxruntime/capi/" + name, data)
        for name in ("LICENSE", "ThirdPartyNotices.txt"):
            if missing and name == "LICENSE":
                continue
            data = (root / name).read_bytes()
            if blank and name == "LICENSE":
                data = b" \n"
            wheel.writestr("onnxruntime/" + name, data)
        if duplicate:
            wheel.writestr("onnxruntime/" + duplicate, b"duplicate")


make_wheel("valid")
make_wheel("wrong", wrong=True)
make_wheel("blank", blank=True)
make_wheel("missing", missing=True)
make_wheel("duplicate-text", duplicate="LICENSE")
make_wheel("duplicate-elf", duplicate="capi/libonnxruntime.so.1.2.3")
(root / "twowheels").mkdir()
(root / "twowheels" / "onnxruntime-1.whl").write_bytes((root / "valid" / "onnxruntime-1-cp315-linux.whl").read_bytes())
(root / "twowheels" / "onnxruntime_dnnl-1.whl").write_bytes((root / "valid" / "onnxruntime-1-cp315-linux.whl").read_bytes())
for case in ("mixed", "corrupt"):
    directory = root / case
    directory.mkdir()
    (directory / "onnxruntime-1-good.whl").write_bytes((root / "valid" / "onnxruntime-1-cp315-linux.whl").read_bytes())
    with zipfile.ZipFile(directory / "onnxruntime-0-other.whl", "w") as wheel:
        data = (root / "build" / "foreign.so").read_bytes() if case == "mixed" else b"bad ELF"
        wheel.writestr("onnxruntime/capi/" + names[0], data)
PY

run_check() {
  python3 "$SCRIPT" --wheel-dir "$work/$1" --destination "$work/bundles/$2" --strip "${3:-strip}" \
    --library "$work/native/libonnxruntime.so.1.2.3" --library "$work/native/libonnxruntime_providers_shared.so"
}
reject_case() {
  mkdir -p "$work/bundles/$1"
  t_assert_fails run_check "$1" "$1" "${2:-strip}"
  t_assert_fails test -e "$work/bundles/$1/licenses/onnxruntime"
}

t_case 'a real debug ELF matches both delivered stripped libraries and preserves original text'
mkdir -p "$work/bundles/good"
t_assert_fails cmp -s "$work/build/libonnxruntime.so.1.2.3" "$work/native/libonnxruntime.so.1.2.3"
t_assert_ok run_check valid good
t_assert_ok cmp "$work/LICENSE" "$work/bundles/good/licenses/onnxruntime/LICENSE"
t_assert_ok cmp "$work/ThirdPartyNotices.txt" "$work/bundles/good/licenses/onnxruntime/ThirdPartyNotices.txt"
t_assert_ok run_check valid good
printf stale > "$work/bundles/good/licenses/onnxruntime/LICENSE"
t_assert_fails run_check valid good
cp "$work/LICENSE" "$work/bundles/good/licenses/onnxruntime/LICENSE"
t_case 'already byte-identical unstripped ELF files are also accepted'
mkdir -p "$work/bundles/raw"
t_assert_ok python3 "$SCRIPT" --wheel-dir "$work/valid" --destination "$work/bundles/raw" --strip strip \
  --library "$work/build/libonnxruntime.so.1.2.3"
t_assert_ok cmp "$work/LICENSE" "$work/bundles/raw/licenses/onnxruntime/LICENSE"
t_case '--require-unstripped accepts exact wheel bytes without a strip tool and rejects stripped copies'
mkdir -p "$work/bundles/exact" "$work/bundles/stripped-refused"
t_assert_ok python3 "$SCRIPT" --wheel-dir "$work/valid" --destination "$work/bundles/exact" \
  --strip missing-strip-tool-for-ort-test --require-unstripped --library "$work/build/libonnxruntime.so.1.2.3"
t_assert_fails python3 "$SCRIPT" --wheel-dir "$work/valid" --destination "$work/bundles/stripped-refused" \
  --strip missing-strip-tool-for-ort-test --require-unstripped --library "$work/native/libonnxruntime.so.1.2.3"
t_assert_fails test -e "$work/bundles/stripped-refused/licenses/onnxruntime"
ln -s libonnxruntime.so.1.2.3 "$work/build/libonnxruntime.so.1"
mkdir -p "$work/bundles/exact-soname"
t_assert_ok python3 "$SCRIPT" --wheel-dir "$work/valid" --destination "$work/bundles/exact-soname" \
  --strip missing-strip-tool-for-ort-test --require-unstripped --library "$work/build/libonnxruntime.so.1"
ln -s libonnxruntime_providers_shared.so "$work/native/libonnxruntime_providers_migraphx.so"
mkdir -p "$work/bundles/provider-alias"
t_assert_fails python3 "$SCRIPT" --wheel-dir "$work/valid" --destination "$work/bundles/provider-alias" \
  --strip strip --library "$work/native/libonnxruntime_providers_migraphx.so"
t_assert_fails test -e "$work/bundles/provider-alias/licenses/onnxruntime"
t_assert_ok python3 - "$SCRIPT" "$work" <<'PY'
import importlib.util
import pathlib
import sys
import zipfile

script, root = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
sys.path.insert(0, str(script.parent))
spec = importlib.util.spec_from_file_location("stage_ort_exact", script)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
scratch = root / "unused-exact-scratch"
with zipfile.ZipFile(root / "valid/onnxruntime-1-cp315-linux.whl") as archive:
    assert module.wheel_has_library(archive, root / "build/libonnxruntime.so.1.2.3", "missing-strip", scratch, True)
    assert not module.wheel_has_library(archive, root / "native/libonnxruntime.so.1.2.3", "missing-strip", scratch, True)
assert not scratch.exists()
PY
t_case 'large library matching uses bounded reads and rejects a member over its limit'
t_assert_ok python3 - "$SCRIPT" "$work" <<'PY'
import importlib.util
import pathlib
import sys
import zipfile

script, root = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
sys.path.insert(0, str(script.parent))
spec = importlib.util.spec_from_file_location("stage_ort", script)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
assert module.MAX_LIBRARY_BYTES > 256 * 1024 * 1024
module.CHUNK_BYTES = 32
library = root / "build/libonnxruntime.so.1.2.3"
with zipfile.ZipFile(root / "valid/onnxruntime-1-cp315-linux.whl") as archive:
    original_open = archive.open
    class LimitedRead:
        def __init__(self, stream): self.stream = stream
        def __enter__(self): return self
        def __exit__(self, *args): self.stream.close()
        def read(self, size=-1):
            assert 0 < size <= module.CHUNK_BYTES
            return self.stream.read(size)
    archive.open = lambda *args, **kwargs: LimitedRead(original_open(*args, **kwargs))
    assert module.wheel_has_library(archive, library, "strip", root / "build")
    module.MAX_LIBRARY_BYTES = library.stat().st_size - 1
    try:
        module.wheel_has_library(archive, library, "strip", root / "build")
    except ValueError as error:
        assert "invalid wheel entry" in str(error)
    else:
        raise AssertionError("an over-limit archive member was accepted")
PY
t_case 'a copied soname still matches the uniquely named versioned wheel entry'
cp "$work/native/libonnxruntime.so.1.2.3" "$work/native/libonnxruntime.so.1"
mkdir -p "$work/bundles/soname"
t_assert_ok python3 "$SCRIPT" --wheel-dir "$work/valid" --destination "$work/bundles/soname" --strip strip \
  --library "$work/native/libonnxruntime.so.1"
t_case 'a different ELF architecture is skipped without invoking the wrong strip tool'
mkdir -p "$work/bundles/mixed"
t_assert_ok run_check mixed mixed
t_assert_ok cmp "$work/LICENSE" "$work/bundles/mixed/licenses/onnxruntime/LICENSE"

t_case 'unmatched providers, missing or blank texts, duplicates and ambiguous wheels are fatal'
for case_name in wrong blank missing duplicate-text duplicate-elf twowheels corrupt; do reject_case "$case_name"; done
t_case 'missing strip tool is fatal even when a candidate is present'
reject_case valid missing-strip-tool-for-ort-test
t_case 'destination symlinks cannot redirect the extracted texts'
mkdir -p "$work/bundles/link" "$work/outside"
ln -s "$work/outside" "$work/bundles/link/licenses"
t_assert_fails run_check valid link
t_assert_fails test -e "$work/outside/onnxruntime"

t_case 'the shared staging wrapper gathers real bundled libraries'
mkdir -p "$work/bundles/wrapped/lib" "$work/bundles/empty/lib"
cp "$work/native/libonnxruntime.so.1.2.3" "$work/bundles/wrapped/lib/"
ORT_CHAIN_WHEEL_DIR="$work/valid" STRIP=strip t_assert_ok stage_ort_wheel_licenses "$work/bundles/wrapped"
t_assert_ok cmp "$work/LICENSE" "$work/bundles/wrapped/licenses/onnxruntime/LICENSE"
ORT_CHAIN_WHEEL_DIR="$work/valid" STRIP=strip t_assert_fails stage_ort_wheel_licenses "$work/bundles/empty"

t_case 'the archive wrapper checks both actual packaged texts'
mkdir -p "$work/package/app/licenses"
cp -a "$work/bundles/wrapped/licenses/onnxruntime" "$work/package/app/licenses/"
tar -C "$work/package" -czf "$work/good.tar.gz" app
t_assert_ok verify_ort_wheel_package_licenses "$work/good.tar.gz" "$work/bundles/wrapped" app
printf wrong > "$work/package/app/licenses/onnxruntime/ThirdPartyNotices.txt"
tar -C "$work/package" -czf "$work/bad.tar.gz" app
t_assert_fails verify_ort_wheel_package_licenses "$work/bad.tar.gz" "$work/bundles/wrapped" app

t_case 'the AppImage wrapper checks both declared paths and the requested architecture'
cat > "$work/appimage" <<'APPIMAGE'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = --appimage-extract ]
case "$2" in usr/lib/app/licenses/onnxruntime/LICENSE|usr/lib/app/licenses/onnxruntime/ThirdPartyNotices.txt|licenses/onnxruntime/LICENSE|licenses/onnxruntime/ThirdPartyNotices.txt) ;; *) exit 2 ;; esac
mkdir -p "squashfs-root/$(dirname "$2")"
if [ "${BAD_NOTICE:-0}" = 1 ] && [[ "$2" == *ThirdPartyNotices.txt ]]; then
  printf wrong > "squashfs-root/$2"
else
  cp "$FIXTURE_LICENSES/$(basename "$2")" "squashfs-root/$2"
fi
APPIMAGE
chmod +x "$work/appimage"
export FIXTURE_LICENSES="$work/bundles/wrapped/licenses/onnxruntime"
t_assert_ok verify_ort_wheel_appimage_licenses "$work/appimage" "$work/bundles/wrapped" "$(uname -m)" usr/lib/app
BAD_NOTICE=1 t_assert_fails verify_ort_wheel_appimage_licenses "$work/appimage" "$work/bundles/wrapped" "$(uname -m)" usr/lib/app
t_assert_ok verify_ort_wheel_appimage_licenses "$work/appimage" "$work/bundles/wrapped" "$(uname -m)" .
BAD_NOTICE=1 t_assert_fails verify_ort_wheel_appimage_licenses "$work/appimage" "$work/bundles/wrapped" "$(uname -m)" .
t_summary
