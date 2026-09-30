#!/usr/bin/env bash
# Codec baseline vs SONAME map convergence. See docs/failure-modes.md#a-soname-with-no-map-entry-is-resolved-by-an-apt-cache-prefix-guess
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"

STV="${TESTS_DIR}/../06-packaging/setup-torch-venv.sh"
MAP="${TESTS_DIR}/../03-media/runtime/so-package-map.txt"

# A two-way ratchet: an entry leaves only with a SONAME verified in a built image, never an invented one.
KNOWN_UNMAPPED=(
  libass9
  libopencore-amrnb0
  libopencore-amrwb0
  libsndio7.0
  libsvtav1enc2
  libswresample6
  libswscale9
  libtbb12
  libvdpau1
  libvpx12
)

# Byte-identical duplicates, benign for the last-wins loader but ratcheted; tab-separated as in the map.
KNOWN_DUP_LINES=(
  $'libdc1394.so.26\tlibdc1394-26'
)

t_case "both hand lists exist where this suite expects them"
t_assert_ok test -f "${STV}"
# A missing map only warns in validate-media-runtime.sh and silently empties resolution.
t_assert_ok test -f "${MAP}"

# Shared extractions

# Data lines of the map (comments/blank stripped), and its mapped packages.
map_lines="$(grep -vE '^([[:space:]]*(#.*)?)$' "${MAP}" || true)"
map_pkgs="$(printf '%s\n' "${map_lines}" | cut -f2 | grep -v '^$' | LC_ALL=C sort -u || true)"

# The baseline's runtime lib packages; comments are stripped so prose cannot leak a name in.
baseline_pkgs="$(awk '/^_install_cv2_runtime_apt\(\)/{f=1} f{print; if ($0 ~ /^}/) exit}' "${STV}" \
  | sed 's/#.*//' \
  | tr ' \t\\' '\n\n\n' \
  | grep -E '^lib[a-z0-9]' \
  | grep -vE -- '-dev$' \
  | LC_ALL=C sort -u || true)"

# Parse guards: an extraction that rots to near-empty must fail, not wave everything through
t_case "extraction guards (a refactor of either list must not gut this suite)"
_baseline_count="$(printf '%s\n' "${baseline_pkgs}" | grep -c . || true)"
_map_count="$(printf '%s\n' "${map_lines}" | grep -c . || true)"
t_assert_ok test "${_baseline_count}" -ge 10
t_assert_ok test "${_map_count}" -ge 50
# Canary: a renamed or moved _install_cv2_runtime_apt trips this first.
t_assert_ok grep -qE '^libavcodec[0-9]+$' <(printf '%s\n' "${baseline_pkgs}")

# INV-1: map format integrity
t_case "INV-1: every map data line is SONAME<TAB>package"
# The loader splits on TAB only; a space-separated line is a silent dead entry.
bad_lines="$(printf '%s\n' "${map_lines}" \
  | grep -vE $'^[A-Za-z0-9._+-]+\\.so[A-Za-z0-9.*]*\t[a-z0-9][a-z0-9.+-]+$' || true)"
t_assert_eq "" "${bad_lines}" "malformed so-package-map.txt line(s) — must be SONAME<TAB>debian-package"

t_case "INV-1: no soname maps to two different packages (loader is last-wins)"
conflicts="$(printf '%s\n' "${map_lines}" | LC_ALL=C sort -u | cut -f1 | LC_ALL=C sort | uniq -d || true)"
t_assert_eq "" "${conflicts}" "soname(s) mapped to conflicting packages — the loader silently keeps only the last"

t_case "INV-1: byte-identical duplicate lines are ratcheted"
dups_now="$(printf '%s\n' "${map_lines}" | LC_ALL=C sort | uniq -d || true)"
dups_known="$(printf '%s\n' "${KNOWN_DUP_LINES[@]}" | LC_ALL=C sort -u)"
t_assert_eq "${dups_known}" "${dups_now}" \
  "duplicate-line set changed — dedupe so-package-map.txt or update KNOWN_DUP_LINES"

# INV-2: the codec baseline converges on the so->package map
unmapped_now="$(LC_ALL=C comm -23 \
  <(printf '%s\n' "${baseline_pkgs}") \
  <(printf '%s\n' "${map_pkgs}") | grep -v '^$' || true)"
unmapped_known="$(printf '%s\n' "${KNOWN_UNMAPPED[@]}" | LC_ALL=C sort -u)"

t_case "INV-2: no NEW baseline package without a so-package-map entry"
new_unmapped="$(LC_ALL=C comm -23 \
  <(printf '%s\n' "${unmapped_now}") \
  <(printf '%s\n' "${unmapped_known}") | grep -v '^$' || true)"
t_assert_eq "" "${new_unmapped}" \
  "codec baseline package(s) with NO soname mapping in so-package-map.txt — add the verified SONAME<TAB>package line (check a built image: dpkg -L <pkg>), or consciously append to KNOWN_UNMAPPED"

t_case "INV-2 ratchet: KNOWN_UNMAPPED only lists entries that are still unmapped"
stale_known="$(LC_ALL=C comm -13 \
  <(printf '%s\n' "${unmapped_now}") \
  <(printf '%s\n' "${unmapped_known}") | grep -v '^$' || true)"
t_assert_eq "" "${stale_known}" \
  "KNOWN_UNMAPPED entry(ies) now mapped or gone from the baseline — remove them so the ratchet keeps shrinking"

t_summary
