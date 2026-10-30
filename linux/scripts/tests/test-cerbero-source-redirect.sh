#!/usr/bin/env bash
# The Cerbero dead-host redirects against recipe lines copied from cerbero 1.29.2; not covered: the live mirrors still serving those bytes.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SRC="${TESTS_DIR}/../03-media/build/gstreamer/android/build-android-from-source.sh"

W="$(mktemp -d)"
trap 'rm -rf "${W}"' EXIT
mkdir -p "${W}/recipes" "${W}/packages"
cat > "${W}/recipes/spandsp.recipe" <<'EOF'
    url = 'https://www.soft-switch.org/downloads/spandsp/spandsp-%(version)s.tar.gz'
    tarball_checksum = 'cc053ac67e8ac4bb992f258fd94f275a7872df959f6a87763965feabfdcc9465'
EOF
cat > "${W}/recipes/pkg-config.recipe" <<'EOF'
    url = 'https://pkgconfig.freedesktop.org/releases/pkg-config-0.29.2.tar.gz'
EOF
printf "    url = 'https://example.invalid/other-1.0.tar.gz'\n" > "${W}/recipes/other.recipe"
cp "${W}/recipes/other.recipe" "${W}/other.before"

_run() {
  ( cd "${W}" && bash -c "$(t_fn_src "${SRC}" cerbero_redirect_source_host)
$(t_fn_src "${SRC}" override_pkgconfig_dead_mirror)
$1" 2>&1 )
}

t_case "spandsp moves to GStreamer's mirror and keeps its checksum"
_out="$(_run 'cerbero_redirect_source_host SPANDSP-MIRROR https://www.soft-switch.org/downloads/spandsp/ https://gstreamer.freedesktop.org/src/mirror/')"
t_assert_contains "$(cat "${W}/recipes/spandsp.recipe")" "url = 'https://gstreamer.freedesktop.org/src/mirror/spandsp-%(version)s.tar.gz'"
t_assert_contains "$(cat "${W}/recipes/spandsp.recipe")" "cc053ac67e8ac4bb992f258fd94f275a7872df959f6a87763965feabfdcc9465"
t_assert_contains "${_out}" "(1 file(s) patched, SPANDSP-MIRROR)"
t_assert_eq "$(cat "${W}/other.before")" "$(cat "${W}/recipes/other.recipe")" "a recipe that names neither host is untouched"

t_case "pkg-config keeps its macports override"
_out="$(_run override_pkgconfig_dead_mirror)"
t_assert_contains "$(cat "${W}/recipes/pkg-config.recipe")" "https://distfiles.macports.org/pkgconfig/pkg-config-0.29.2.tar.gz"
t_assert_contains "${_out}" "pkg-config mirror override"

t_case "the build redirects spandsp before cerbero fetches"
t_assert_contains "$(cat "${SRC}")" "cerbero_redirect_source_host SPANDSP-MIRROR https://www.soft-switch.org/downloads/spandsp/ https://gstreamer.freedesktop.org/src/mirror/"
t_assert_contains "$(cat "${SRC}")" "cerbero_redirect_source_host ZBAR-MIRROR https://linuxtv.org/downloads/zbar/ https://web.archive.org/web/2025id_/https://linuxtv.org/downloads/zbar/" \
  "linuxtv.org sits behind a JavaScript bot challenge since 2026-10-29 (HTML for curl, wget and cerbero alike); the Wayback id_ view keeps the recipe's checksum 78ae427a"

t_summary
