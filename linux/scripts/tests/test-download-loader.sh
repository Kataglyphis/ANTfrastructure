#!/usr/bin/env bash
# Loader ownership and verified XZ extraction run without network access.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
HELPER="${TESTS_DIR}/../01-core/download-loader.sh"
GST="${TESTS_DIR}/../03-media/build/gstreamer/android/build-gstreamer.sh"
FLUTTER="${TESTS_DIR}/../05-frameworks/flutter/setup-flutter.sh"
WORK="$(mktemp -d)"
REPO_ROOT="$(cd "${TESTS_DIR}/../../.." && pwd)"
trap 'rm -rf "${WORK}"' EXIT

_core_fixture() {
  local name="$1"
  mkdir -p "${WORK}/${name}/core"
  cp "${HELPER}" "${WORK}/${name}/core/download-loader.sh"
  printf '%s\n' "${WORK}/${name}/core"
}

_run() { bash -c "$1" _ "${@:2}"; }

_core="$(_core_fixture automatic)"
cat > "${_core}/downloads.sh" <<'EOF'
download_and_extract() { printf 'loaded'; }
EOF
t_case "the loader resolves downloads.sh beside its own source"
t_assert_eq loaded "$(_run 'set -euo pipefail; source "$1/download-loader.sh"; download_module_load; download_and_extract' "${_core}")"

_core="$(_core_fixture override)"
cat > "${_core}/downloads.sh" <<EOF
: > "${WORK}/override/sourced"
download_and_extract() { printf 'file'; }
EOF
t_case "a caller-provided downloader keeps precedence"
t_assert_eq caller "$(_run 'set -euo pipefail; source "$1/download-loader.sh"; download_and_extract() { printf caller; }; download_module_load; download_and_extract' "${_core}")"
t_assert_fails test -e "${WORK}/override/sourced"

mkdir -p "${WORK}/payload"
printf 'payload\n' > "${WORK}/payload/item.txt"
tar -cJf "${WORK}/payload.tar.xz" -C "${WORK}/payload" item.txt
_core="$(_core_fixture extract)"
VERIFY_LOG="${WORK}/verification"
ARCHIVE_FIXTURE="${WORK}/payload.tar.xz"
export VERIFY_LOG ARCHIVE_FIXTURE
t_case "verified extraction forwards pins and removes the successful archive"
t_assert_eq "done" "$(_run 'set -euo pipefail; source "$1/download-loader.sh"; download_verified_file() { printf "%s|%s|%s" "$1" "$2" "$3" > "$VERIFY_LOG"; cp "$ARCHIVE_FIXTURE" "$3"; }; download_verified_extract_xz URL SHA "$2/archive.tar.xz" "$2/destination"; printf done' "${_core}" "${WORK}/extract")"
t_assert_eq "URL|SHA|${WORK}/extract/archive.tar.xz" "$(cat "${WORK}/verification")"
t_assert_eq payload "$(cat "${WORK}/extract/destination/item.txt")"
t_assert_fails test -e "${WORK}/extract/archive.tar.xz"

t_case "verification failure stops before destination creation"
_rc="$(_run 'set -euo pipefail; source "$1/download-loader.sh"; download_verified_file() { return 7; }; if download_verified_extract_xz URL SHA "$2/archive.tar.xz" "$2/missing-destination"; then exit 1; else printf "%s" "$?"; fi' "${_core}" "${WORK}/extract" 2>/dev/null)"
t_assert_eq 7 "${_rc}"
t_assert_fails test -e "${WORK}/extract/missing-destination"

t_case "an invalid archive propagates tar failure and remains for diagnosis"
printf 'not an xz archive\n' > "${WORK}/extract/invalid.tar.xz"
INVALID_ARCHIVE="${WORK}/extract/invalid.tar.xz"
export INVALID_ARCHIVE
_rc="$(_run 'set -euo pipefail; source "$1/download-loader.sh"; download_verified_file() { cp "$INVALID_ARCHIVE" "$3"; }; if download_verified_extract_xz URL SHA "$2/invalid.tar.xz" "$2/invalid-destination"; then exit 1; else printf "%s" "$?"; fi' "${_core}" "${WORK}/extract" 2>/dev/null)"
t_assert_ok test "${_rc}" -ne 0
t_assert_ok test -e "${WORK}/extract/invalid.tar.xz"

t_case "GStreamer resolves its download loader through the shared module framework"
t_assert_eq "function" "$(_run 'set -euo pipefail; SCRIPTS_ROOT="$1/linux/scripts"; SCRIPT_DIR="$SCRIPTS_ROOT/03-media/build/gstreamer/android"; source "$SCRIPTS_ROOT/01-core/modules.sh"; source_module download-loader.sh; type -t download_module_load' "${REPO_ROOT}")"

t_case "Flutter retains its unverified fallback when the checkout has no checksum pin"
_flutter_root="${WORK}/flutter-unverified/linux/scripts"
mkdir -p "${_flutter_root}/05-frameworks/flutter" "${_flutter_root}/01-core"
cp "${FLUTTER}" "${_flutter_root}/05-frameworks/flutter/setup-flutter.sh"
cp "${HELPER}" "${_flutter_root}/01-core/download-loader.sh"
DOWNLOAD_LOG="${WORK}/flutter-download"
export DOWNLOAD_LOG
_out="$(_run 'set -euo pipefail; download_and_extract() { printf "%s|%s" "$1" "$2" > "$DOWNLOAD_LOG"; }; source "$1/setup-flutter.sh" --arch x64 --version 3.44.4 --dir "$2"' "${_flutter_root}/05-frameworks/flutter" "${WORK}/flutter-install" 2>&1)"
t_assert_contains "${_out}" 'fetching the Flutter toolchain UNVERIFIED'
t_assert_eq "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.44.4-stable.tar.xz|${WORK}/flutter-install" "$(cat "${DOWNLOAD_LOG}")"

t_case "GStreamer and Flutter use the shared loader and verified extractor"
t_assert_contains "$(cat "${GST}")" 'source_module download-loader.sh'
t_assert_contains "$(cat "${GST}")" 'download_module_load'
t_assert_contains "$(cat "${GST}")" 'download_verified_extract_xz'
t_assert_contains "$(cat "${FLUTTER}")" '_flutter_download_loader="/opt/scripts/core/download-loader.sh"'
t_assert_contains "$(cat "${FLUTTER}")" 'source "${_flutter_download_loader}"'
t_assert_contains "$(cat "${FLUTTER}")" 'download_module_load'
t_assert_contains "$(cat "${FLUTTER}")" 'download_verified_extract_xz'

t_summary
