#!/usr/bin/env bash
# test-codec-so-map-convergence.sh — backlog item "codec runtime-list +
# so-package-map convergence" (docs/refactoring-backlog.md).
#
# THREE truths describe which apt packages provide the media/codec runtime
# shared libraries:
#
#   1. the hand-maintained codec-lib baseline in
#      06-packaging/setup-torch-venv.sh :: _install_cv2_runtime_apt — the
#      torch stage's fallback install list when the ffmpeg manifest is absent;
#   2. the hand-maintained SONAME->package map
#      03-media/runtime/so-package-map.txt — validate-media-runtime.sh uses it
#      to deterministically resolve a missing soname to its package; WITHOUT
#      an entry it degrades to dpkg-query and then an apt-cache PREFIX GUESS
#      (`apt-cache search "^${base}[0-9]" | head -1` — an arbitrary pick);
#   3. /opt/ffmpeg/runtime-apt-packages.txt (emit_runtime_apt_manifest in
#      build-ffmpeg.sh) — the ground truth, but it exists only INSIDE a built
#      image, so no static test can reach it.
#
# This suite freezes the statically checkable convergence between (1) and (2):
#
#   INV-1  so-package-map.txt is well-formed: every data line is exactly
#          `SONAME<TAB>package`, and no soname maps to two DIFFERENT packages
#          (known_so_packages_load is last-wins, so a conflicting duplicate is
#          a SILENT override). Byte-identical duplicate lines are ratcheted.
#   INV-2  every versioned runtime lib package hardcoded in the codec baseline
#          appears as a mapping target in so-package-map.txt — both hand lists
#          must agree which Ubuntu package provides each media library. When a
#          baseline bump (libx265-215 -> libx265-2xx) forgets the map, the
#          media validator silently degrades to prefix-guessing for exactly
#          that library: the drift class this suite exists to make loud.
#
# KNOWN_UNMAPPED is a RATCHET, not an excuse list: it records the divergence
# that already existed when this suite landed (2026-08-24), because inventing
# map entries would require knowing the real SONAME each package ships — only
# verifiable against a built image (governing rule: don't invent data). The
# ratchet fails in BOTH directions: a NEW unmapped baseline package fails
# immediately (add the verified `SONAME<TAB>package` line to so-package-map.txt,
# or consciously append here), and an entry that stops being unmapped — or
# leaves the baseline — fails until it is removed here, so the list can only
# shrink honestly.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"

STV="${TESTS_DIR}/../06-packaging/setup-torch-venv.sh"
MAP="${TESTS_DIR}/../03-media/runtime/so-package-map.txt"

# Divergence recorded 2026-08-24 (see suite header). Per-entry notes:
#   libvpx12 / libswscale9 / libswresample6 — the map still carries the OLDER
#     names (libvpx9 / libswscale8 / libswresample5): live version drift
#     between the two hand lists, the exact class this suite guards.
#   libopencore-amrwb0 — the package whose missing runtime lib caused the
#     2026-07-11 `libopencore-amrwb.so.0: cannot open shared object` failure
#     that motivated emit_runtime_apt_manifest; its soname mapping is STILL
#     absent from the map.
#   libass9 libopencore-amrnb0 libsndio7.0 libsvtav1enc2 libtbb12 libvdpau1 —
#     never had map entries.
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

# Byte-identical duplicate data lines present today (benign for the last-wins
# loader, but hygiene worth ratcheting). Tab-separated, exactly as in the map.
KNOWN_DUP_LINES=(
  $'libdc1394.so.26\tlibdc1394-26'
)

t_case "both hand lists exist where this suite expects them"
t_assert_ok test -f "${STV}"
# A moved/deleted map is NOT benign: known_so_packages_load in
# validate-media-runtime.sh only WARNS and continues with an empty map,
# silently gutting deterministic soname resolution — so fail loud here.
t_assert_ok test -f "${MAP}"

# ---------------------------------------------------------------------------
# Shared extractions
# ---------------------------------------------------------------------------

# Data lines of the map (comments/blank stripped), and its mapped packages.
map_lines="$(grep -vE '^([[:space:]]*(#.*)?)$' "${MAP}" || true)"
map_pkgs="$(printf '%s\n' "${map_lines}" | cut -f2 | grep -v '^$' | LC_ALL=C sort -u || true)"

# The codec-lib baseline: runtime lib packages (lib*, never -dev) listed in
# _install_cv2_runtime_apt. Comments are stripped first so prose mentioning a
# library name can never leak into the package set.
baseline_pkgs="$(awk '/^_install_cv2_runtime_apt\(\)/{f=1} f{print; if ($0 ~ /^}/) exit}' "${STV}" \
  | sed 's/#.*//' \
  | tr ' \t\\' '\n\n\n' \
  | grep -E '^lib[a-z0-9]' \
  | grep -vE -- '-dev$' \
  | LC_ALL=C sort -u || true)"

# ---------------------------------------------------------------------------
# Parse guards — an extraction that silently rots to (near-)empty must FAIL,
# not wave everything through (the "toothless gate" class).
# ---------------------------------------------------------------------------
t_case "extraction guards (a refactor of either list must not gut this suite)"
_baseline_count="$(printf '%s\n' "${baseline_pkgs}" | grep -c . || true)"
_map_count="$(printf '%s\n' "${map_lines}" | grep -c . || true)"
t_assert_ok test "${_baseline_count}" -ge 10
t_assert_ok test "${_map_count}" -ge 50
# Canary: the baseline always carries a versioned libavcodec runtime package;
# if _install_cv2_runtime_apt is renamed/moved this trips before anything else.
t_assert_ok grep -qE '^libavcodec[0-9]+$' <(printf '%s\n' "${baseline_pkgs}")

# ---------------------------------------------------------------------------
# INV-1: map format integrity
# ---------------------------------------------------------------------------
t_case "INV-1: every map data line is SONAME<TAB>package"
# known_so_packages_load splits on TAB only: a space-separated line puts the
# WHOLE line into so_name and an empty string into pkg — a silent dead entry.
bad_lines="$(printf '%s\n' "${map_lines}" \
  | grep -vE $'^[A-Za-z0-9._+-]+\\.so[A-Za-z0-9.]*\t[a-z0-9][a-z0-9.+-]+$' || true)"
t_assert_eq "" "${bad_lines}" "malformed so-package-map.txt line(s) — must be SONAME<TAB>debian-package"

t_case "INV-1: no soname maps to two different packages (loader is last-wins)"
conflicts="$(printf '%s\n' "${map_lines}" | LC_ALL=C sort -u | cut -f1 | LC_ALL=C sort | uniq -d || true)"
t_assert_eq "" "${conflicts}" "soname(s) mapped to conflicting packages — the loader silently keeps only the last"

t_case "INV-1: byte-identical duplicate lines are ratcheted"
dups_now="$(printf '%s\n' "${map_lines}" | LC_ALL=C sort | uniq -d || true)"
dups_known="$(printf '%s\n' "${KNOWN_DUP_LINES[@]}" | LC_ALL=C sort -u)"
t_assert_eq "${dups_known}" "${dups_now}" \
  "duplicate-line set changed — dedupe so-package-map.txt or update KNOWN_DUP_LINES"

# ---------------------------------------------------------------------------
# INV-2: codec baseline converges on the so->package map
# ---------------------------------------------------------------------------
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
