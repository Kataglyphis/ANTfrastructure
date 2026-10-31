#!/usr/bin/env bash
# Checks exact ZIP/MSIX/wheel and embedded MSI bytes; it does not prove source provenance.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SCRIPT="${TESTS_DIR}/../verify_package_binary.py"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
python3 "$TESTS_DIR/package_binary_archive_fixture.py" "$work"

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
cp "$TESTS_DIR/package-msi-7z-fixture.sh" "$work/tools/7z"
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
