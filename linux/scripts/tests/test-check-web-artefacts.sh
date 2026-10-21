#!/usr/bin/env bash
# check-web-artefacts.py on throwaway app trees: each pin it guards, met and broken.
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

_gate() { "${PREFLIGHT_PYTHON:-python3}" "${SCRIPTS}/05-frameworks/flutter/check-web-artefacts.py" --repo-root "$1"; }

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

t_case "a directory without pubspec.yaml is a usage error"
mkdir -p "${work}/empty"
t_assert_rc 2 _gate "${work}/empty"

t_summary
