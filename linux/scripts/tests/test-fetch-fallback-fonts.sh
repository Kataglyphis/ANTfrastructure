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

t_case "a store holding every file places them with no download and no cache, even with every download refused"
mkdir -p "${w}/store/emoji/v1" "${w}/store/sym/v2"
cp "${w}/e.0.woff2" "${w}/e.1.woff2" "${w}/store/emoji/v1/"
cp "${w}/s.woff2" "${w}/store/sym/v2/"
t_assert_ok env HTTPS_PROXY=http://127.0.0.1:9 "${PY}" -I "${FONTS}" --engine-data "${w}/engine.dart" --lock "${w}/fonts.lock" --store "${w}/store" --cache "${w}/nocache" --dest "${w}/from-store"
t_assert_eq "bytes of emoji/v1/e.1.woff2" "$(cat "${w}/from-store/emoji/v1/e.1.woff2" 2>&1)"
t_assert_eq 3 "$(find "${w}/from-store" -type f | wc -l | tr -d ' ')"
t_assert_ok test ! -e "${w}/nocache"

t_case "a file the store lacks comes through the cache; KATAGLYPHIS_FONT_STORE names the store"
mkdir -p "${w}/partial/emoji/v1"
cp "${w}/e.0.woff2" "${w}/partial/emoji/v1/"
t_assert_ok env KATAGLYPHIS_FONT_STORE="${w}/partial" "${PY}" -I "${FONTS}" --engine-data "${w}/engine.dart" --lock "${w}/fonts.lock" --cache "${w}/cache" --dest "${w}/mixed"
t_assert_eq 3 "$(find "${w}/mixed" -type f | wc -l | tr -d ' ')"

t_case "a transition line serves the older Flutter's engine all of its own rows and nothing else, and no partial match"
# The suite's first lock and engine stand for the older generation; the lock under test moved emoji to v2.
mkdir -p "${w}/tr"
cp "${w}/fonts.lock" "${w}/tr/old.lock"
moved=(emoji/v2/e.0.woff2 sym/v2/s.woff2)
printf '# transition: Flutter 1.0, rows in old.lock\n' > "${w}/tr/fonts.lock"
for p in "${moved[@]}"; do line "${p}"; done >> "${w}/tr/fonts.lock"
_engine "${w}/new.dart" "${moved[@]}"
tr_fetch() { "${PY}" -I "${FONTS}" --engine-data "${w}/$1.dart" --cache "${w}/cache" --lock "${w}/tr/fonts.lock" --dest "${w}/tr-$1"; }
files() { (cd "$1" && find . -type f | sed 's#^\./##' | sort | tr '\n' ' ' | sed 's/ $//'); }
t_assert_contains "$(t_out tr_fetch engine)" "3 fallback fonts of 2 families in ${w}/tr-engine (Flutter 1.0's transition rows)"
t_assert_eq "emoji/v1/e.0.woff2 emoji/v1/e.1.woff2 sym/v2/s.woff2" "$(files "${w}/tr-engine")"
t_assert_eq "2 fallback fonts of 2 families in ${w}/tr-new" "$(t_out tr_fetch new)"
t_assert_eq "emoji/v2/e.0.woff2 sym/v2/s.woff2" "$(files "${w}/tr-new")"
t_assert_rc 1 tr_fetch more
t_assert_contains "$(t_out tr_fetch more)" "nor is this Flutter 1.0's engine, whose rows old.lock holds"
t_assert_ok test ! -e "${w}/tr-more"

t_case "a transition lock is a file beside the lock, never a path elsewhere"
mkdir -p "${w}/tr/sub"
sed 's#rows in old.lock#rows in ../old.lock#' "${w}/tr/fonts.lock" > "${w}/tr/sub/fonts.lock"
t_assert_rc 2 "${PY}" -I "${FONTS}" --engine-data "${w}/engine.dart" --lock "${w}/tr/sub/fonts.lock" --check
t_assert_contains "$(t_out "${PY}" -I "${FONTS}" --engine-data "${w}/engine.dart" --lock "${w}/tr/sub/fonts.lock" --check)" "the transition lock '../old.lock' is no file beside it"

t_case "--print-generations lists the lock's font paths, then its transition lock's, each after its lock's name, with no engine"
t_assert_eq "$(printf 'fonts.lock\temoji/v2/e.0.woff2\nfonts.lock\tsym/v2/s.woff2\nold.lock\temoji/v1/e.0.woff2\nold.lock\temoji/v1/e.1.woff2\nold.lock\tsym/v2/s.woff2')" "$("${PY}" -I "${FONTS}" --engine-data "${w}/none.dart" --lock "${w}/tr/fonts.lock" --print-generations)"
t_assert_eq "$(printf 'fonts.lock\temoji/v1/e.0.woff2\nfonts.lock\temoji/v1/e.1.woff2\nfonts.lock\tsym/v2/s.woff2')" "$("${PY}" -I "${FONTS}" --lock "${w}/fonts.lock" --print-generations)"
t_assert_rc 2 "${PY}" -I "${FONTS}" --lock "${w}/tr/sub/fonts.lock" --print-generations

# In the family image the hub's own lock is graded against the SDK the lanes build with.
ENGINE_LIST=/opt/flutter/engine/src/flutter/lib/web_ui/lib/src/engine/font_fallback_data.dart
if [ -f "${ENGINE_LIST}" ]; then
  t_case "the hub's lock holds every chunk of its families, as the image's engine requests them"
  t_assert_ok "${PY}" -I "${FONTS}" --engine-data "${ENGINE_LIST}" --check
fi

t_summary
