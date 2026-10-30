#!/usr/bin/env bash
# Checks exact ZIP/MSIX/wheel and embedded MSI bytes; it does not prove source provenance.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SCRIPT="${TESTS_DIR}/../verify_package_binary.py"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
python3 - "$work" <<'PY'
import pathlib
import sys
import warnings
import zipfile

root = pathlib.Path(sys.argv[1])
data = (b'MZ\r\n\x00\xffabcdef' * (18 * 1024 * 1024 // 12 + 1))[:18 * 1024 * 1024]
(root / 'provider.dll').write_bytes(data)
(root / 'wrong.dll').write_bytes(data[:-1] + bytes([data[-1] ^ 1]))
(root / 'empty.dll').write_bytes(b'')
for name in ('app.zip', 'app.msix', 'app.whl'):
    with zipfile.ZipFile(root / name, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr('app/onnxruntime_providers_cuda.dll', data)
        archive.writestr('app/shared.dll', b'shared\r\n')
(root / 'shared.dll').write_bytes(b'shared\r\n')
with zipfile.ZipFile(root / 'duplicate.zip', 'w') as archive:
    archive.writestr('app/onnxruntime_providers_cuda.dll', data)
    archive.writestr('app/ONNXRUNTIME_PROVIDERS_CUDA.dll', data)
with zipfile.ZipFile(root / 'alias.zip', 'w') as archive:
    archive.writestr('app/onnxruntime_providers_cuda.dll', data)
    archive.writestr('app/./onnxruntime_providers_cuda.dll', data)
with zipfile.ZipFile(root / 'leading-dot.zip', 'w') as archive:
    archive.writestr('./app/onnxruntime_providers_cuda.dll', data)
with warnings.catch_warnings():
    warnings.simplefilter('ignore', UserWarning)
    with zipfile.ZipFile(root / 'duplicate-exact.zip', 'w') as archive:
        archive.writestr('app/onnxruntime_providers_cuda.dll', data)
        archive.writestr('app/onnxruntime_providers_cuda.dll', data)
with zipfile.ZipFile(root / 'symlink.zip', 'w') as archive:
    link = zipfile.ZipInfo('app/onnxruntime_providers_cuda.dll')
    link.create_system = 3
    link.external_attr = 0o120777 << 16
    archive.writestr(link, data)
with zipfile.ZipFile(root / 'unsafe.zip', 'w') as archive:
    archive.writestr('../escape', b'x')
    archive.writestr('app/onnxruntime_providers_cuda.dll', data)
PY

t_case 'ZIP, MSIX and wheel check exact bytes for large members without a license text size limit'
for package in app.zip app.msix app.whl; do
  t_assert_ok python3 -I "$SCRIPT" "$work/$package" --require "app/onnxruntime_providers_cuda.dll=$work/provider.dll"
  t_assert_ok python3 -I "$SCRIPT" "$work/$package" --require "app/onnxruntime_providers_cuda.dll=$work/provider.dll" --require "app/shared.dll=$work/shared.dll"
done
t_assert_fails python3 -I "$SCRIPT" "$work/app.whl" --require "app/onnxruntime_providers_cuda.dll=$work/wrong.dll"
t_case 'missing, changed, ambiguous and unsafe ZIP members fail closed'
t_assert_fails python3 -I "$SCRIPT" "$work/app.zip" --require "app/onnxruntime_providers_cuda.dll=$work/wrong.dll"
t_assert_fails python3 -I "$SCRIPT" "$work/app.zip" --require "app/missing.dll=$work/provider.dll"
t_assert_fails python3 -I "$SCRIPT" "$work/app.zip" --require "app/*.dll=$work/provider.dll"
t_assert_fails python3 -I "$SCRIPT" "$work/app.zip" --require "app/onnxruntime_providers_cuda.dll=$work/empty.dll"
t_assert_fails python3 -I "$SCRIPT" "$work/app.zip" --require "app/shared.dll=$work/shared.dll" --require "app/SHARED.dll=$work/shared.dll"
t_assert_fails python3 -I "$SCRIPT" "$work/duplicate.zip" --require "app/onnxruntime_providers_cuda.dll=$work/provider.dll"
t_assert_fails python3 -I "$SCRIPT" "$work/duplicate-exact.zip" --require "app/onnxruntime_providers_cuda.dll=$work/provider.dll"
t_assert_fails python3 -I "$SCRIPT" "$work/alias.zip" --require "app/onnxruntime_providers_cuda.dll=$work/provider.dll"
t_assert_fails python3 -I "$SCRIPT" "$work/leading-dot.zip" --require "app/onnxruntime_providers_cuda.dll=$work/provider.dll"
t_assert_fails python3 -I "$SCRIPT" "$work/app.zip" --require "./app/onnxruntime_providers_cuda.dll=$work/provider.dll"
t_assert_fails python3 -I "$SCRIPT" "$work/symlink.zip" --require "app/onnxruntime_providers_cuda.dll=$work/provider.dll"
t_assert_fails python3 -I "$SCRIPT" "$work/unsafe.zip" --require "app/onnxruntime_providers_cuda.dll=$work/provider.dll"

t_case 'MSI media mapping selects one embedded cabinet and streams its exact member'
mkdir -p "$work/tools"
cat > "$work/tools/7z" <<'SH'
#!/usr/bin/env bash
set -u
operation="$1"
archive="${@: -2:1}"
member="${@: -1}"
if [ "$operation" = l ]; then
  archive="${@: -1}"
  printf '%s\n' '----------'
  if [[ "$archive" == *.msi ]]; then
    printf '%s\n' 'Path = cab1.cab' 'Path = cab2.cab'
  elif [ "$(cat "$archive")" = CAB2 ]; then
    printf '%s\n' 'Path = f9179'
    [ "${FAKE_DUPLICATE:-0}" = 0 ] || printf '%s\n' 'Path = f9179'
  fi
elif [ "$operation" = e ]; then
  if [[ "$archive" == *.msi ]]; then
    [ "${FAKE_CAB_FAIL:-0}" = 0 ] || exit 9
    case "$member" in cab1.cab) printf CAB1 ;; cab2.cab) printf CAB2 ;; *) exit 1 ;; esac
  else
    [ "$member" = f9179 ] || exit 1
    [ "${FAKE_MEMBER_FAIL:-0}" = 0 ] || exit 8
    cat "$FAKE_BINARY"
  fi
else
  exit 1
fi
SH
chmod +x "$work/tools/7z"
touch "$work/multi.msi"
export FAKE_BINARY="$work/provider.dll"
PATH="$work/tools:$PATH" t_assert_ok python3 -I "$SCRIPT" "$work/multi.msi" --require "cab2.cab::f9179=$work/provider.dll"
PATH="$work/tools:$PATH" t_assert_fails python3 -I "$SCRIPT" "$work/multi.msi" --require "cab1.cab::f9179=$work/provider.dll"
PATH="$work/tools:$PATH" t_assert_fails python3 -I "$SCRIPT" "$work/multi.msi" --require "external.cab::f9179=$work/provider.dll"
PATH="$work/tools:$PATH" t_assert_fails python3 -I "$SCRIPT" "$work/multi.msi" --require "f9179=$work/provider.dll"
PATH="$work/tools:$PATH" t_assert_fails python3 -I "$SCRIPT" "$work/multi.msi" --require "cab2.cab::f9*=$work/provider.dll"
FAKE_DUPLICATE=1 PATH="$work/tools:$PATH" t_assert_fails python3 -I "$SCRIPT" "$work/multi.msi" --require "cab2.cab::f9179=$work/provider.dll"
FAKE_CAB_FAIL=1 PATH="$work/tools:$PATH" t_assert_fails python3 -I "$SCRIPT" "$work/multi.msi" --require "cab2.cab::f9179=$work/provider.dll"
FAKE_MEMBER_FAIL=1 PATH="$work/tools:$PATH" t_assert_fails python3 -I "$SCRIPT" "$work/multi.msi" --require "cab2.cab::f9179=$work/provider.dll"
FAKE_BINARY="$work/wrong.dll" PATH="$work/tools:$PATH" t_assert_fails python3 -I "$SCRIPT" "$work/multi.msi" --require "cab2.cab::f9179=$work/provider.dll"
unset FAKE_BINARY
t_summary
