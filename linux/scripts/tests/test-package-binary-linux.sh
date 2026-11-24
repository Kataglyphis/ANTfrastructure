#!/usr/bin/env bash
# Synthetic members prove exact-byte and transport verdicts, not ELF ABI, permissions, loaders or source provenance.
set -u
tests_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$tests_dir/test-harness.sh"
t_skip_unless 'dpkg-deb' command -v dpkg-deb
script="$tests_dir/../verify_package_binary.py"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
python3 "$tests_dir/package_binary_linux_fixture.py" "$work" || exit $?
member=app/onnxruntime_providers_cuda.dll
rule="$member=$work/provider.dll"
t_case 'large TAR and directory members retain exact bytes without text normalization'
source "$tests_dir/fixtures/binary-package-cases.sh"
t_binary_package_cases "$script" "$work" app.tar app.tar.gz dot.tar.gz tree
t_case 'TAR aliases, duplicates, traversal and nonregular selected members are rejected'
for package in duplicate duplicate-dot case double-dot alias unsafe symlink hardlink directory; do
  t_assert_fails python3 -I "$script" "$work/$package.tar.gz" --require "$rule"
done
t_case 'directory symlinks, linked parents and case aliases cannot substitute for delivered regular files'
for package in symlink-tree link-tree alias-tree root-link; do
  t_assert_fails python3 -I "$script" "$work/$package" --require "$rule"
done
t_case 'a real DEB payload reaches the same exact-byte verifier'
mkdir -p "$work/tree/DEBIAN"
cat > "$work/tree/DEBIAN/control" <<'CONTROL'
Package: binary-fixture
Version: 1
Architecture: all
Maintainer: Fixture <fixture@example.invalid>
Description: Controlled binary payload
CONTROL
dpkg-deb --root-owner-group -Zgzip --build "$work/tree" "$work/app.deb" >/dev/null || exit $?
t_assert_ok python3 -I "$script" "$work/app.deb" --require "$rule"
t_assert_fails python3 -I "$script" "$work/app.deb" --require "$member=$work/wrong.dll"
t_case 'complete valid DEB payload bytes do not conceal a failed native reader'
mkdir "$work/tools"
cp "$tests_dir/fixtures/deb-payload-reader.sh" "$work/tools/dpkg-deb"
chmod +x "$work/tools/dpkg-deb"
export FAKE_DEB_TAR="$work/app-tail.tar" FAKE_DEB_STATUS=37
PATH="$work/tools:$PATH" t_assert_fails python3 -I "$script" "$work/app.deb" --require "$rule"
PATH="$work/tools:$PATH" python3 -I "$script" "$work/app.deb" --require "$rule" > "$work/reader.out" 2>&1
t_assert_contains "$(cat "$work/reader.out")" 'dpkg-deb could not read the package: 37'
t_summary
