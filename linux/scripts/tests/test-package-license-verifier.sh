#!/usr/bin/env bash
# Verifies declared archive texts, not all dependency obligations; see docs/third-party-licenses.md § Checking delivered package licences.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SCRIPT="${TESTS_DIR}/../verify_package_license.py"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

printf 'Copyright Example\nPermission is granted.\n' > "$work/LICENSE"
mkdir -p "$work/tree/share/doc/app" "$work/tree/DEBIAN"
cp "$work/LICENSE" "$work/tree/share/doc/app/LICENSE"
printf 'Package: app\nVersion: 1.0\nArchitecture: all\nMaintainer: Test <test@example.invalid>\nDescription: test\n' > "$work/tree/DEBIAN/control"
python3 - "$work" <<'PY'
import gzip
import pathlib
import sys
import tarfile
import zipfile

root = pathlib.Path(sys.argv[1])
license_text = (root / "LICENSE").read_bytes()
with zipfile.ZipFile(root / "app.zip", "w") as archive:
    archive.writestr("assets/NOTICES.Z", gzip.compress(b"app\n\n" + license_text))
    archive.writestr("share/doc/app/LICENSE", license_text)
with tarfile.open(root / "app.tar.gz", "w:gz") as archive:
    archive.add(root / "tree/share/doc/app/LICENSE", arcname="app/LICENSE")
with zipfile.ZipFile(root / "wrong.zip", "w") as archive:
    archive.writestr("share/doc/app/LICENSE", b"unrelated text")
    archive.writestr("assets/NOTICES.Z", b"bad compressed content")
with zipfile.ZipFile(root / "bad-gzip.zip", "w") as archive:
    archive.writestr("assets/NOTICES.Z", b"\x1f\x8b" + b"not-a-gzip-stream")
with zipfile.ZipFile(root / "link.zip", "w") as archive:
    entry = zipfile.ZipInfo("LICENSE")
    entry.create_system = 3
    entry.external_attr = 0o120777 << 16
    archive.writestr(entry, license_text)
PY

t_case 'the complete project license is present in directory, tar and zip payloads'
t_assert_ok python3 "$SCRIPT" "$work/tree" --require "share/doc/app/LICENSE=$work/LICENSE"
t_assert_ok python3 "$SCRIPT" "$work/app.tar.gz" --require "app/LICENSE=$work/LICENSE"
t_assert_ok python3 "$SCRIPT" "$work/app.zip" --require "share/doc/*/LICENSE=$work/LICENSE"

t_case 'a compressed Flutter notice contains the entire expected text'
t_assert_ok python3 "$SCRIPT" "$work/app.zip" --require "assets/NOTICES.Z=$work/LICENSE"

t_case 'missing, incomplete and misdirected licenses fail'
t_assert_fails python3 "$SCRIPT" "$work/wrong.zip" --require "share/doc/app/LICENSE=$work/LICENSE"
t_assert_fails python3 "$SCRIPT" "$work/bad-gzip.zip" --require "assets/NOTICES.Z=$work/LICENSE"
t_assert_fails python3 "$SCRIPT" "$work/link.zip" --require "LICENSE=$work/LICENSE"
t_assert_fails python3 "$SCRIPT" "$work/app.zip" --require "missing/LICENSE=$work/LICENSE"
t_assert_fails python3 "$SCRIPT" "$work/app.zip" --require "assets/NOTICES.Z=$work/LICENSE" --require "missing/LICENSE=$work/LICENSE"
printf '' > "$work/empty"
t_assert_fails python3 "$SCRIPT" "$work/app.zip" --require "share/doc/app/LICENSE=$work/empty"
t_assert_fails python3 "$SCRIPT" "$work/app.zip" --require "invalid-rule"

t_case 'a real deb payload is checked without extraction'
t_needs 'dpkg-deb' command -v dpkg-deb
dpkg-deb --build "$work/tree" "$work/app.deb" >/dev/null
t_assert_ok python3 "$SCRIPT" "$work/app.deb" --require "share/doc/app/LICENSE=$work/LICENSE"
rm "$work/tree/share/doc/app/LICENSE"
dpkg-deb --build "$work/tree" "$work/mutant.deb" >/dev/null
t_assert_fails python3 "$SCRIPT" "$work/mutant.deb" --require "share/doc/app/LICENSE=$work/LICENSE"

t_case 'Flatpak import and checkout are required and the delivered text is checked'
mkdir -p "$work/tools"
cat > "$work/tools/flatpak" <<'SH'
#!/usr/bin/env bash
exit "${FAKE_FLATPAK_RC:-0}"
SH
cat > "$work/tools/ostree" <<'SH'
#!/usr/bin/env bash
case "$1" in
  init) exit 0 ;;
  refs) printf '%s\n' "${FAKE_REF:-app/org.example.Demo/x86_64/stable}" ;;
  checkout)
    target="${@: -1}"
    mkdir -p "$target/files/lib/demo"
    cp "$FAKE_LICENSE" "$target/files/lib/demo/LICENSE" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$work/tools/flatpak" "$work/tools/ostree"
touch "$work/fixture.flatpak"
export FAKE_LICENSE="$work/LICENSE"
PATH="$work/tools:$PATH" t_assert_ok python3 "$SCRIPT" "$work/fixture.flatpak" --require "files/lib/demo/LICENSE=$work/LICENSE"
printf 'wrong terms\n' > "$work/wrong-license"
FAKE_LICENSE="$work/wrong-license" PATH="$work/tools:$PATH" t_assert_fails python3 "$SCRIPT" "$work/fixture.flatpak" --require "files/lib/demo/LICENSE=$work/LICENSE"
FAKE_FLATPAK_RC=7 PATH="$work/tools:$PATH" t_assert_fails python3 "$SCRIPT" "$work/fixture.flatpak" --require "files/lib/demo/LICENSE=$work/LICENSE"
FAKE_REF=$'app/org.example.Demo/x86_64/stable\napp/org.example.Other/x86_64/stable' PATH="$work/tools:$PATH" \
  t_assert_fails python3 "$SCRIPT" "$work/fixture.flatpak" --require "files/lib/demo/LICENSE=$work/LICENSE"
unset FAKE_LICENSE

if command -v flatpak >/dev/null 2>&1 && command -v ostree >/dev/null 2>&1; then
  t_case 'a real Flatpak carries the original project license'
  _arch="$(flatpak --default-arch)"
  mkdir -p "$work/flatpak-app/files/lib/demo" "$work/flatpak-app/files/bin"
  printf '[Application]\nname=org.example.Demo\nruntime=org.freedesktop.Platform/%s/25.08\nsdk=org.freedesktop.Sdk/%s/25.08\ncommand=demo\n' "$_arch" "$_arch" > "$work/flatpak-app/metadata"
  cp "$work/LICENSE" "$work/flatpak-app/files/lib/demo/LICENSE"
  printf '#!/bin/sh\n' > "$work/flatpak-app/files/bin/demo"
  chmod +x "$work/flatpak-app/files/bin/demo"
  t_assert_ok flatpak build-finish "$work/flatpak-app"
  t_assert_ok flatpak build-export --arch="$_arch" "$work/flatpak-repo" "$work/flatpak-app" stable
  t_assert_ok flatpak build-bundle --arch="$_arch" "$work/flatpak-repo" "$work/real.flatpak" org.example.Demo stable
  t_assert_ok python3 "$SCRIPT" "$work/real.flatpak" --require "files/lib/demo/LICENSE=$work/LICENSE"
  t_assert_fails python3 "$SCRIPT" "$work/real.flatpak" --require "files/lib/demo/missing=$work/LICENSE"
fi

if command -v 7z >/dev/null 2>&1; then
  t_case '7-Zip archive members are read without extracting them to disk'
  (cd "$work" && 7z a -t7z fixture.appimage LICENSE >/dev/null)
  t_assert_ok python3 "$SCRIPT" "$work/fixture.appimage" --require "LICENSE=$work/LICENSE"
  t_assert_fails python3 "$SCRIPT" "$work/fixture.appimage" --require "absent=$work/LICENSE"
fi

t_case 'MSI media mappings select the right embedded cabinet and reject ambiguity'
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
    if [[ " $* " != *' -tCompound '* ]]; then printf '%s\n' 'Path = f9179'; exit 0; fi
    printf '%s\n' 'Path = cab1.cab'
    [ "${FAKE_MSI_SINGLE:-0}" = 1 ] || printf '%s\n' 'Path = cab2.cab'
  elif [ "$(cat "$archive")" = CAB2 ] || [ "${FAKE_MSI_SINGLE:-0}" = 1 ] || [ "${FAKE_BOTH_CONTAIN:-0}" = 1 ]; then
    printf '%s\n' 'Path = f9179'
    [ "${FAKE_DUPLICATE:-0}" = 0 ] || printf '%s\n' 'Path = f9179'
  fi
elif [ "$operation" = e ]; then
  if [ "${FAKE_EXTRACT_FAIL:-0}" != 0 ] && [[ "$archive" == *.msi ]]; then printf CAB2; exit 9; fi
  if [[ "$archive" == *.msi ]]; then
    case "$member" in cab1.cab) printf CAB1 ;; cab2.cab) printf CAB2 ;; external.cab) [ "${FAKE_ACCEPT_EXTERNAL:-0}" = 1 ] && printf CAB2 ;; *) exit 1 ;; esac
  else
    [ "$member" = f9179 ] || exit 1
    cat "$FAKE_LICENSE"
  fi
else
  exit 1
fi
SH
chmod +x "$work/tools/7z"
touch "$work/multi.msi"
export FAKE_LICENSE="$work/LICENSE"
PATH="$work/tools:$PATH" t_assert_ok python3 "$SCRIPT" "$work/multi.msi" --require "cab2.cab::f9179=$work/LICENSE"
PATH="$work/tools:$PATH" t_assert_fails python3 "$SCRIPT" "$work/multi.msi" --require "cab1.cab::f9179=$work/LICENSE"
PATH="$work/tools:$PATH" t_assert_fails python3 "$SCRIPT" "$work/multi.msi" --require "f9179=$work/LICENSE"
FAKE_BOTH_CONTAIN=1 PATH="$work/tools:$PATH" t_assert_fails python3 "$SCRIPT" "$work/multi.msi" --require "f9179=$work/LICENSE"
FAKE_ACCEPT_EXTERNAL=1 PATH="$work/tools:$PATH" t_assert_fails python3 "$SCRIPT" "$work/multi.msi" --require "external.cab::f9179=$work/LICENSE"
FAKE_MSI_SINGLE=1 PATH="$work/tools:$PATH" t_assert_ok python3 "$SCRIPT" "$work/multi.msi" --require "f9179=$work/LICENSE"
FAKE_MSI_SINGLE=1 PATH="$work/tools:$PATH" t_assert_ok python3 "$SCRIPT" "$work/multi.msi" --require "cab1.cab::f9179=$work/LICENSE"
FAKE_DUPLICATE=1 PATH="$work/tools:$PATH" t_assert_fails python3 "$SCRIPT" "$work/multi.msi" --require "cab2.cab::f9179=$work/LICENSE"
FAKE_EXTRACT_FAIL=1 PATH="$work/tools:$PATH" t_assert_fails python3 "$SCRIPT" "$work/multi.msi" --require "cab2.cab::f9179=$work/LICENSE"
unset FAKE_LICENSE

t_summary
