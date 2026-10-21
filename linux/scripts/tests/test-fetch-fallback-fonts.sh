#!/usr/bin/env bash
# fetch-fallback-fonts.py over a fixture engine list and a seeded cache: the engine check both ways, the <family>/<version>/<file> layout. See linux/webserver/README.md#fallback-fonts-from-the-site
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
FONTS="${TESTS_DIR}/../05-frameworks/flutter/fetch-fallback-fonts.py"
PY="${PREFLIGHT_PYTHON:-python3}"

t_skip_unless "a POSIX python3" t_posix_python

w="$(mktemp -d)"
trap 'rm -rf "${w}"' EXIT
G="https://fonts.gstatic.com/s"

# _engine <file> <path>...: a font_fallback_data.dart that requests these paths.
_engine() {
  local out="$1" p
  shift
  { printf "List<NotoFont> getFallbackFontList() => <NotoFont>[\n"
    for p in "$@"; do printf "  NotoFont(\n    'Font %s',\n    '%s',\n  ),\n" "${p}" "${p}"; done
    printf "];\n"; } > "${out}"
}

# The cache already holds every file, so no case downloads: the fetcher reads <sha256>-<file> first.
mkdir -p "${w}/cache"
line() {
  local name="${1##*/}" sha
  printf 'bytes of %s' "$1" > "${w}/${name}"
  sha="$(sha256sum "${w}/${name}" | cut -d' ' -f1)"
  cp "${w}/${name}" "${w}/cache/${sha}-${name}"
  printf '%s  %s  %s/%s\n' "${sha}" "${name}" "${G}" "$1"
}
{ printf '# sha256 file url\n'; line emoji/v1/e.0.woff2; line emoji/v1/e.1.woff2; line sym/v2/s.woff2; } > "${w}/fonts.lock"
_engine "${w}/engine.dart" emoji/v1/e.0.woff2 emoji/v1/e.1.woff2 sym/v2/s.woff2 cjk/v3/c.woff2
fetch() { "${PY}" -I "${FONTS}" --engine-data "${w}/engine.dart" --cache "${w}/cache" "$@"; }

t_case "every locked font lands at <dest>/<family>/<version>/<file>, readable by all, the engine's other families left out"
t_assert_ok fetch --lock "${w}/fonts.lock" --dest "${w}/web/fallback-fonts"
t_assert_eq "bytes of emoji/v1/e.1.woff2" "$(cat "${w}/web/fallback-fonts/emoji/v1/e.1.woff2" 2>&1)"
t_assert_eq "bytes of sym/v2/s.woff2" "$(cat "${w}/web/fallback-fonts/sym/v2/s.woff2" 2>&1)"
t_assert_eq 644 "$(stat -c %a "${w}/web/fallback-fonts/emoji/v1/e.0.woff2")"
t_assert_eq 3 "$(find "${w}/web/fallback-fonts" -type f | wc -l | tr -d ' ')"

t_case "--check compares and writes nothing"
t_assert_ok fetch --lock "${w}/fonts.lock" --check

t_case "a locked file this engine never requests fails, naming the re-pin, and writes nothing"
_engine "${w}/moved.dart" emoji/v2/e.0.woff2 emoji/v2/e.1.woff2 sym/v2/s.woff2
t_assert_rc 1 "${PY}" -I "${FONTS}" --engine-data "${w}/moved.dart" --cache "${w}/cache" --lock "${w}/fonts.lock" --dest "${w}/moved"
t_assert_contains "$(t_out "${PY}" -I "${FONTS}" --engine-data "${w}/moved.dart" --lock "${w}/fonts.lock" --check)" "never requests emoji/v1/e.0.woff2; Flutter moved, re-pin with --print-lock emoji"
t_assert_ok test ! -e "${w}/moved"

t_case "a chunk of a locked family the lock lacks fails"
_engine "${w}/more.dart" emoji/v1/e.0.woff2 emoji/v1/e.1.woff2 emoji/v1/e.2.woff2 sym/v2/s.woff2
t_assert_contains "$(t_out "${PY}" -I "${FONTS}" --engine-data "${w}/more.dart" --lock "${w}/fonts.lock" --check)" "emoji/v1/e.2.woff2: the engine requests it for a locked family, the lock lacks it"
t_assert_rc 1 "${PY}" -I "${FONTS}" --engine-data "${w}/more.dart" --lock "${w}/fonts.lock" --check

t_case "a URL off the engine's base, or naming another file, fails"
sed 's#https://fonts.gstatic.com/s/sym#https://example.org/sym#' "${w}/fonts.lock" > "${w}/elsewhere.lock"
t_assert_contains "$(t_out fetch --lock "${w}/elsewhere.lock" --check)" "is not ${G}/<family>/<version>/s.woff2"

t_case "no engine list is a usage error"
t_assert_rc 2 "${PY}" -I "${FONTS}" --engine-data "${w}/none.dart" --lock "${w}/fonts.lock" --check
t_assert_rc 2 fetch --lock "${w}/none.lock" --check
t_assert_rc 2 fetch --print-lock nosuchfamily

# In the family image the hub's own lock is graded against the SDK the lanes build with.
ENGINE_LIST=/opt/flutter/engine/src/flutter/lib/web_ui/lib/src/engine/font_fallback_data.dart
if [ -f "${ENGINE_LIST}" ]; then
  t_case "the hub's lock holds every chunk of its families, as the image's engine requests them"
  t_assert_ok "${PY}" -I "${FONTS}" --engine-data "${ENGINE_LIST}" --check
fi

t_summary
