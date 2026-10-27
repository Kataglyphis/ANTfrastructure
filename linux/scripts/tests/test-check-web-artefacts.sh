#!/usr/bin/env bash
# check-web-artefacts.py on throwaway app trees: each pin and icon path it guards, met and broken.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "${TESTS_DIR}/.." && pwd)"
source "${TESTS_DIR}/test-harness.sh"
ENV_FILE="${SCRIPTS}/01-core/versions.env"
WASM_VERSION="$(sed -n 's/^SQLITE3_WASM_VERSION=//p' "${ENV_FILE}")"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

# _png <file> <bit depth>: the 25 bytes up to IHDR's bit depth, all the gate reads.
_png() {
  mkdir -p "$(dirname "$1")"
  printf '\211PNG\r\n\032\n\000\000\000\015IHDR\000\000\000\020\000\000\000\020\'"$(printf '%03o' "$2")" > "$1"
}

# _app <dir>: a tree that passes; the cases below break one thing each.
_app() {
  mkdir -p "$1/web/icons"
  printf 'name: fixture\n' > "$1/pubspec.yaml"
  printf '<html><head><title>Fixture</title></head></html>\n' > "$1/web/index.html"
  printf '{"name": "Fixture"}\n' > "$1/web/manifest.json"
  _png "$1/web/favicon.png" 8
  _png "$1/web/icons/Icon-192.png" 8
}

_gate() { local root="$1"; shift; "${PREFLIGHT_PYTHON:-python3}" "${SCRIPTS}/05-frameworks/flutter/check-web-artefacts.py" --repo-root "${root}" "$@"; }

t_case "a tree that keeps every pin passes"
_app "${work}/ok"
t_assert_rc 0 _gate "${work}/ok"

t_case "a <title> the manifest does not share fails, naming both"
_app "${work}/title"
printf '{"name": "Other"}\n' > "${work}/title/web/manifest.json"
t_assert_rc 1 _gate "${work}/title"
t_assert_contains "$(t_out _gate "${work}/title")" "'Fixture' but web/manifest.json's name is 'Other'"

t_case "a 16-bit icon fails and is named"
_app "${work}/deep"
_png "${work}/deep/android/app/src/main/res/mipmap-hdpi/launcher_icon.png" 16
t_assert_rc 1 _gate "${work}/deep"
t_assert_contains "$(t_out _gate "${work}/deep")" "android/app/src/main/res/mipmap-hdpi/launcher_icon.png"

t_case "a sqlite3.wasm that is not the pinned build fails"
_app "${work}/wasm"
printf 'not the release asset' > "${work}/wasm/web/sqlite3.wasm"
t_assert_rc 1 _gate "${work}/wasm"
t_assert_contains "$(t_out _gate "${work}/wasm")" "not SQLITE3_WASM_SHA256"

t_case "a lock on another sqlite3 than the wasm's release fails"
_app "${work}/lock"
printf 'packages:\n  sqlite3:\n    dependency: "direct main"\n    version: "0.0.1"\n' > "${work}/lock/pubspec.lock"
: > "${work}/lock/web/sqlite3.wasm"
t_assert_contains "$(t_out _gate "${work}/lock")" "pubspec.lock resolves sqlite3 0.0.1 but web/sqlite3.wasm is the ${WASM_VERSION} build"

t_case "no sqlite3.wasm: the sqlite pins do not apply"
_app "${work}/nowasm"
printf 'packages:\n  sqlite3:\n    version: "0.0.1"\n' > "${work}/nowasm/pubspec.lock"
t_assert_rc 0 _gate "${work}/nowasm"

_manifest_icons() { printf '{"name": "Fixture", "icons": [{"src": "%s"}]}\n' "$2" > "$1/web/manifest.json"; }

t_case "a manifest icon web/ does not hold fails, naming it"
_app "${work}/gone"
_manifest_icons "${work}/gone" icons/Icon-512.png
t_assert_rc 1 _gate "${work}/gone"
t_assert_contains "$(t_out _gate "${work}/gone")" "web/manifest.json names icons/Icon-512.png, which web/ does not hold"

t_case "so does an apple-touch-icon"
_app "${work}/touch"
printf '<html><head><title>Fixture</title><link rel="apple-touch-icon" href="icons/Icon-180.png"></head></html>\n' > "${work}/touch/web/index.html"
t_assert_contains "$(t_out _gate "${work}/touch")" "web/index.html names icons/Icon-180.png, which web/ does not hold"

t_case "the manifest's icons must lie in --icons-dir"
_app "${work}/dir"
mkdir -p "${work}/dir/web/app-icons"
_png "${work}/dir/web/app-icons/Icon-192.png" 8
_manifest_icons "${work}/dir" app-icons/Icon-192.png
t_assert_contains "$(t_out _gate "${work}/dir")" "outside the icon directory web/icons/"
t_assert_rc 0 "${PREFLIGHT_PYTHON:-python3}" "${SCRIPTS}/05-frameworks/flutter/check-web-artefacts.py" --repo-root "${work}/dir" --icons-dir app-icons

t_case "on Apache (a web/.htaccess) a file under web/icons/ fails: Apache aliases /icons/ to its own directory"
_app "${work}/apache"
: > "${work}/apache/web/.htaccess"
t_assert_rc 1 _gate "${work}/apache"
t_assert_contains "$(t_out _gate "${work}/apache")" "Apache serves /icons/ from its own directory, so these 404 on the site: web/icons/Icon-192.png"

t_case "and so does an absolute og:image under /icons/, with the icons moved"
_app "${work}/og"
: > "${work}/og/web/.htaccess"
mv "${work}/og/web/icons" "${work}/og/web/app-icons"
printf '<html><head><title>Fixture</title><meta property="og:image" content="https://example.org/icons/Icon-512.png"></head></html>\n' > "${work}/og/web/index.html"
t_assert_contains "$(t_out _gate "${work}/og" --icons-dir app-icons)" "404 on the site: https://example.org/icons/Icon-512.png"
printf '<html><head><title>Fixture</title><meta property="og:image" content="https://example.org/app-icons/Icon-192.png"></head></html>\n' > "${work}/og/web/index.html"
t_assert_rc 0 _gate "${work}/og"

t_case "a directory without pubspec.yaml is a usage error"
mkdir -p "${work}/empty"
t_assert_rc 2 _gate "${work}/empty"

t_case "an Android application ships its declared launcher in every standard density"
_app "${work}/android"
_android="${work}/android/android/app/src/main"
mkdir -p "${_android}"
printf '%s\n' '<manifest xmlns:android="http://schemas.android.com/apk/res/android"><application android:icon="@mipmap/launcher_icon" /></manifest>' > "${_android}/AndroidManifest.xml"
for _density in mdpi hdpi xhdpi xxhdpi xxxhdpi; do
  mkdir -p "${_android}/res/mipmap-${_density}"
  t_write_png "${_android}/res/mipmap-${_density}/launcher_icon.png" 1 1
done
t_assert_rc 0 _gate "${work}/android"
rm "${_android}/res/mipmap-hdpi/launcher_icon.png"
t_assert_rc 1 _gate "${work}/android"
t_assert_contains "$(t_out _gate "${work}/android")" 'missing Android launcher icon: android/app/src/main/res/mipmap-hdpi/launcher_icon.png'
t_write_png "${_android}/res/mipmap-hdpi/launcher_icon.png" 1 1
printf 'corrupt' > "${_android}/res/mipmap-xxhdpi/launcher_icon.png"
t_assert_contains "$(t_out _gate "${work}/android")" 'invalid Android launcher PNG: android/app/src/main/res/mipmap-xxhdpi/launcher_icon.png'
t_write_png "${_android}/res/mipmap-xxhdpi/launcher_icon.png" 1 1
printf '%s\n' '<manifest xmlns:android="http://schemas.android.com/apk/res/android"><application /></manifest>' > "${_android}/AndroidManifest.xml"
t_assert_contains "$(t_out _gate "${work}/android")" 'needs a supported @mipmap launcher icon'
printf '<manifest' > "${_android}/AndroidManifest.xml"
t_assert_contains "$(t_out _gate "${work}/android")" 'is malformed'

t_summary
