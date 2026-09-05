#!/usr/bin/env bash
# Parity suite for the intentionally-bundled cross_build_is_active fallback
# clones (01-core/common.sh, gstreamer/common/build-gstreamer-monorepo.sh).
# Bundling is policy; DRIFT is the bug — this file has drifted twice (arch
# normalization missed 4 of 5 copies; the cross_build_enabled delegation missed
# the monorepo copy). The 03-media/core/common.sh copy is GONE: it sat behind an
# assertion in the same function that already refuses to continue without the
# function, so it could never execute. That coupling is asserted below.
# Assert BEHAVIOR parity of the fallback in three scenarios instead of
# diffing text (comments/locals may differ).
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"

_probe() {
  # $1 = file, $2 = fn-extraction context, $3... = env; runs the fallback
  # definition in a clean bash with cross_build_is_active undefined.
  local file="$1"; shift
  bash -c "
    arch_normalize() { case \"\$1\" in x86_64) echo amd64;; aarch64) echo arm64;; *) echo \"\$1\";; esac; }
    # extract just the guarded fallback definition block
    src=\$(awk '/if ! command -v cross_build_is_active/,/^  fi\$|^fi\$/' '${file}')
    eval \"\${src}\"
    $* cross_build_is_active && echo ACTIVE || echo INACTIVE
  " 2>/dev/null
}

# 01-core/common.sh delegates at SOURCE time (structurally different,
# semantically equivalent) — awk extraction doesn't fit it; assert its
# structure directly instead of its behavior.
t_case "01-core/common.sh: source-time delegation to cross_build_enabled present"
t_assert_ok grep -q 'cross_build_is_active() { cross_build_enabled; }' "${TESTS_DIR}/../01-core/common.sh"

# ── why 03-media/core/common.sh carries no copy any more ────────────────────
# media_common_init sources its critical modules, then asserts with `declare -F`
# that log, cross_build_is_active and mem_capped_jobs exist and RETURNS 1 when one
# does not. A `command -v cross_build_is_active` guard sixteen lines further down
# could therefore never be true. Deleting a fallback because an assertion above it
# makes it unreachable couples two independent things — so the coupling is pinned
# here: put the fallback back if this assertion ever stops naming the function.
MEDIA_COMMON="${TESTS_DIR}/../03-media/core/common.sh"
_MEDIA_INIT_SRC="$(t_fn_src "${MEDIA_COMMON}" media_common_init)" || exit 1

t_case "media_common_init still REFUSES to continue without cross_build_is_active"
t_assert_contains "${_MEDIA_INIT_SRC}" 'for _fn in log cross_build_is_active mem_capped_jobs; do' \
  "this is the only reason the 03-media fallback could be deleted"
t_assert_contains "${_MEDIA_INIT_SRC}" "critical module(s) did not load" "and it must still be a hard return 1"
t_assert_contains "${_MEDIA_INIT_SRC}" 'if [ -n "${_missing}" ]; then' \
  "a warning instead of a branch would let the caller reach a function that is not there"

t_case "and it carries no unreachable clone of the fallback"
t_assert_eq "" "$(printf '%s\n' "${_MEDIA_INIT_SRC}" | grep -e 'cross_build_is_active() {')" \
  "16 lines that could not execute, and one more copy to keep in parity"

FILES=(
  "${TESTS_DIR}/../03-media/build/gstreamer/common/build-gstreamer-monorepo.sh"
)

for f in "${FILES[@]}"; do
  name="$(basename "$(dirname "${f}")")/$(basename "${f}")"

  t_case "${name}: cross+foreign arch => ACTIVE"
  t_assert_eq "ACTIVE" "$(_probe "${f}" BUILD_MODE=cross TARGET_ARCH=arm64 BUILDARCH=amd64)"

  t_case "${name}: cross+same arch => INACTIVE (OCI vs uname normalization)"
  t_assert_eq "INACTIVE" "$(_probe "${f}" BUILD_MODE=cross TARGET_ARCH=arm64 BUILDARCH=aarch64)"

  t_case "${name}: native => INACTIVE"
  t_assert_eq "INACTIVE" "$(_probe "${f}" BUILD_MODE=native TARGET_ARCH=arm64 BUILDARCH=amd64)"

  t_case "${name}: delegates to cross_build_enabled when defined"
  out="$(bash -c "
    arch_normalize() { echo \"\$1\"; }
    cross_build_enabled() { return 0; }
    src=\$(awk '/if ! command -v cross_build_is_active/,/^  fi\$|^fi\$/' '${f}')
    eval \"\${src}\"
    BUILD_MODE=native cross_build_is_active && echo DELEGATED || echo RAW
  " 2>/dev/null)"
  t_assert_eq "DELEGATED" "${out}" "authoritative predicate must win over the approximation"
done

# ---------------------------------------------------------------------------
# APT-HTTP restore parity (2026-08-24): bootstrap_ca deliberately downgrades a
# https fast-mirror to http:// for the CA bootstrap; restore_mirror_https_scheme
# (base-image.sh, exposed as the restore-mirror-scheme subcommand) must undo
# EXACTLY that — and nothing else. Exercised here against fixture sources via
# UBUNTU_SOURCES_ROOT with the REAL scripts, mirroring the in-image sequence:
# downgrade -> ca-install marker -> restore.
# ---------------------------------------------------------------------------
CORE_DIR="${TESTS_DIR}/../01-core"
_MIRROR_TMP="$(mktemp -d)"
trap 'rm -rf "${_MIRROR_TMP}"' EXIT

_mirror_fixture() {
  # $1 = root dir, $2 = URIs value for the archive stanza
  mkdir -p "$1/etc/apt/sources.list.d"
  printf 'Types: deb\nURIs: %s\nSuites: resolute\nComponents: main\n\nTypes: deb\nURIs: http://security.ubuntu.com/ubuntu/\nSuites: resolute-security\nComponents: main\n' \
    "$2" > "$1/etc/apt/sources.list.d/ubuntu.sources"
}

_mirror_downgrade() {
  # $1 = root; runs the REAL bootstrap-style rewrite with the http URL that
  # bootstrap_ca passes (security rewrite on, as the worst case)
  USE_FAST_UBUNTU_MIRROR=true FAST_UBUNTU_MIRROR_URL=http://mirror.invalid/ubuntu/ \
  FAST_UBUNTU_REWRITE_SECURITY=true UBUNTU_SOURCES_ROOT="$1" \
    bash "${CORE_DIR}/use-fast-ubuntu-mirror.sh" >/dev/null 2>&1
}

_mirror_restore() {
  # $1 = root, $2 = configured mirror URL, $3 = knob (default true)
  USE_FAST_UBUNTU_MIRROR="${3:-true}" FAST_UBUNTU_MIRROR_URL="$2" \
  UBUNTU_SOURCES_ROOT="$1" \
    bash "${CORE_DIR}/base-image.sh" restore-mirror-scheme >/dev/null 2>&1
}

_mirror_uris() { grep '^URIs:' "$1/etc/apt/sources.list.d/ubuntu.sources" | tr '\n' '|'; }

# -- happy path: downgrade -> install marker -> restore -> https ------------
R="${_MIRROR_TMP}/happy"
_mirror_fixture "${R}" "http://archive.ubuntu.com/ubuntu/"
t_case "apt-http: bootstrap downgrade lands http mirror (archive+security)"
t_assert_ok _mirror_downgrade "${R}"
t_assert_eq "URIs: http://mirror.invalid/ubuntu/|URIs: http://mirror.invalid/ubuntu/|" "$(_mirror_uris "${R}")"

# The ordering contract lives in base-image.sh itself: bootstrap-ca installs
# ca-certificates and THEN calls restore_mirror_https_scheme. Assert that
# ordering statically on the production file — the first version of this case
# touched a marker file and asserted its own touch, which could never fail
# (caught by adversarial review 2026-08-24).
t_case "apt-http: base-image.sh restores the scheme AFTER installing ca-certificates"
_bi="${CORE_DIR}/base-image.sh"
_ca_line="$(grep -n 'install -y --no-install-recommends ca-certificates' "${_bi}" | head -1 | cut -d: -f1)"
_rs_line="$(grep -n '^  restore_mirror_https_scheme$' "${_bi}" | head -1 | cut -d: -f1)"
if [ -n "${_ca_line}" ] && [ -n "${_rs_line}" ] && [ "${_rs_line}" -gt "${_ca_line}" ]; then
  t_assert_eq ok ok
else
  t_assert_eq "restore after ca-install" "ordering broken (ca=${_ca_line:-none}, restore=${_rs_line:-none})"
fi

t_case "apt-http: restore puts archive AND security entries back on https"
t_assert_ok _mirror_restore "${R}" "https://mirror.invalid/ubuntu/"
t_assert_eq "URIs: https://mirror.invalid/ubuntu/|URIs: https://mirror.invalid/ubuntu/|" "$(_mirror_uris "${R}")"

t_case "apt-http: restore is idempotent (second run leaves file byte-identical)"
_before="$(cat "${R}/etc/apt/sources.list.d/ubuntu.sources")"
t_assert_ok _mirror_restore "${R}" "https://mirror.invalid/ubuntu/"
t_assert_eq "${_before}" "$(cat "${R}/etc/apt/sources.list.d/ubuntu.sources")"

# -- derived ports URL (arm64/riscv64-shaped sources) -----------------------
R="${_MIRROR_TMP}/ports"
mkdir -p "${R}/etc/apt/sources.list.d"
printf 'Types: deb\nURIs: http://ports.ubuntu.com/ubuntu-ports/\nSuites: resolute\nComponents: main\n' \
  > "${R}/etc/apt/sources.list.d/ubuntu.sources"
t_case "apt-http: derived ports mirror is restored to https too"
_mirror_downgrade "${R}"
t_assert_ok _mirror_restore "${R}" "https://mirror.invalid/ubuntu/"
t_assert_eq "URIs: https://mirror.invalid/ubuntu-ports/|" "$(_mirror_uris "${R}")"

# -- no-op cases ------------------------------------------------------------
R="${_MIRROR_TMP}/knoboff"
_mirror_fixture "${R}" "http://mirror.invalid/ubuntu/"
_before="$(cat "${R}/etc/apt/sources.list.d/ubuntu.sources")"
t_case "apt-http: knob off => rc 0 and sources untouched"
t_assert_ok _mirror_restore "${R}" "https://mirror.invalid/ubuntu/" false
t_assert_eq "${_before}" "$(cat "${R}/etc/apt/sources.list.d/ubuntu.sources")"

t_case "apt-http: user explicitly chose an http mirror => rc 0 and untouched"
t_assert_ok _mirror_restore "${R}" "http://mirror.invalid/ubuntu/" true
t_assert_eq "${_before}" "$(cat "${R}/etc/apt/sources.list.d/ubuntu.sources")"

t_summary
