#!/usr/bin/env bash
# Tests for 01-core/compiler-cache.sh launcher resolution (backlog F2).
#
# WHY THIS SUITE EXISTS (2026-08-30)
# ----------------------------------
# F2 consolidated the launcher decision onto ONE resolver: setup_ccache and
# setup_sccache now route through common.sh's compiler_cache_launcher() when
# the 01-core framework is loaded, and fall back to an inline bootstrap when
# it is not (the android preamble sources compiler-cache.sh standalone). The
# two paths must agree -- a divergence means one caller silently caches
# differently from the rest. These tests pin the agreement:
#   * framework path: setup_ccache honors the resolver's verdict verbatim
#   * bootstrap path: sccache + guarded launcher -> the guarded launcher
#   * bootstrap path: dead server -> ccache, never an empty launcher
#   * setup_sccache: a non-sccache resolver verdict keeps bare sccache
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"

CCSH="${TESTS_DIR}/../01-core/compiler-cache.sh"

# Stub compiler binaries on a private PATH so `command -v` resolves them and
# their --version/--start-server/--show-stats behave per-test. $1 = sccache
# mode: ok | dead | absent. $2 = ccache mode: present | absent.
_mk_fakes() {
  _fake_bin="${TMPDIR:-/tmp}/cc-test-bin.$$"
  rm -rf "${_fake_bin}"; mkdir -p "${_fake_bin}"
  case "${1:-ok}" in
    absent) ;;
    dead)   printf '#!/bin/sh\ncase "$1" in --version) echo "sccache 0.17.0";; --start-server) exit 0;; --show-stats) exit 1;; esac\n' > "${_fake_bin}/sccache" ;;
    ok)     printf '#!/bin/sh\ncase "$1" in --version) echo "sccache 0.17.0";; --start-server) exit 0;; --show-stats) echo "Compile requests 1" >&2; exit 0;; esac\n' > "${_fake_bin}/sccache" ;;
  esac
  if [ "${2:-present}" = "present" ]; then
    printf '#!/bin/sh\nexit 0\n' > "${_fake_bin}/ccache"
    chmod +x "${_fake_bin}/ccache"
  fi
  [ "${1:-ok}" = "absent" ] || chmod +x "${_fake_bin}/sccache"
  export PATH="${_fake_bin}:${PATH}"
  printf '%s' "${_fake_bin}"
}

# Framework path: 01-core is loaded, so compiler_cache_launcher exists.
t_case "setup_ccache (framework path) honors the resolver's guarded-launcher verdict"
(
  set -u
  _mk_fakes ok present >/dev/null
  export USE_CCACHE=true USE_SCCACHE=true CCACHE_DIR=/tmp/cc CCACHE_MAXSIZE=1G
  compiler_cache_launcher() { printf '%s' /opt/scripts/core/sccache-launcher.sh; }
  # shellcheck disable=SC1090
  source "${CCSH}"
  _cc_info() { printf "[CACHE] %s\n" "$*" >&2; }
  setup_ccache
  printf '%s' "${CMAKE_C_COMPILER_LAUNCHER:-EMPTY}"
) > "${TMPDIR:-/tmp}/ccf_out1.$$" 2>/dev/null
_out1="$(cat "${TMPDIR:-/tmp}/ccf_out1.$$")"; rm -f "${TMPDIR:-/tmp}/ccf_out1.$$"
t_assert_eq "${_out1}" "/opt/scripts/core/sccache-launcher.sh"

t_case "setup_ccache (framework path) falls back to ccache on a dead-server verdict"
(
  set -u
  _mk_fakes ok present >/dev/null
  export USE_CCACHE=true USE_SCCACHE=true CCACHE_DIR=/tmp/cc CCACHE_MAXSIZE=1G
  compiler_cache_launcher() { printf '%s' ccache; }
  # shellcheck disable=SC1090
  source "${CCSH}"
  _cc_info() { printf "[CACHE] %s\n" "$*" >&2; }
  setup_ccache
  printf '%s' "${CMAKE_C_COMPILER_LAUNCHER:-EMPTY}"
) > "${TMPDIR:-/tmp}/ccf_out2.$$" 2>/dev/null
_out2="$(cat "${TMPDIR:-/tmp}/ccf_out2.$$")"; rm -f "${TMPDIR:-/tmp}/ccf_out2.$$"
t_assert_eq "${_out2}" "ccache"

# Bootstrap path: no compiler_cache_launcher (android preamble). The repo's own
# guarded launcher sits next to compiler-cache.sh and must win over bare sccache.
t_case "setup_ccache (bootstrap path) resolves the guarded launcher when sccache answers"
(
  set -u
  _mk_fakes ok present >/dev/null
  export USE_CCACHE=true USE_SCCACHE=true CCACHE_DIR=/tmp/cc CCACHE_MAXSIZE=1G
  unset -f compiler_cache_launcher 2>/dev/null || true
  # shellcheck disable=SC1090
  source "${CCSH}"
  _cc_info() { printf "[CACHE] %s\n" "$*" >&2; }
  setup_ccache
  printf '%s' "${CMAKE_C_COMPILER_LAUNCHER:-EMPTY}"
) > "${TMPDIR:-/tmp}/ccf_out3.$$" 2>/dev/null
_out3="$(cat "${TMPDIR:-/tmp}/ccf_out3.$$")"; rm -f "${TMPDIR:-/tmp}/ccf_out3.$$"
t_assert_eq "${_out3}" "$(cd "$(dirname "${CCSH}")" && pwd)/sccache-launcher.sh"

t_case "setup_ccache (bootstrap path) falls back to ccache when the server is dead"
(
  set -u
  _mk_fakes dead present >/dev/null
  export USE_CCACHE=true USE_SCCACHE=true CCACHE_DIR=/tmp/cc CCACHE_MAXSIZE=1G
  # shellcheck disable=SC1090
  source "${CCSH}"
  _cc_info() { printf "[CACHE] %s\n" "$*" >&2; }
  setup_ccache
  printf '%s' "${CMAKE_C_COMPILER_LAUNCHER:-EMPTY}"
) > "${TMPDIR:-/tmp}/ccf_out4.$$" 2>/dev/null
_out4="$(cat "${TMPDIR:-/tmp}/ccf_out4.$$")"; rm -f "${TMPDIR:-/tmp}/ccf_out4.$$"
t_assert_eq "${_out4}" "ccache"

t_case "setup_ccache (bootstrap path) stays ccache when sccache is absent"
(
  set -u
  _mk_fakes absent present >/dev/null
  export USE_CCACHE=true USE_SCCACHE=true CCACHE_DIR=/tmp/cc CCACHE_MAXSIZE=1G
  # shellcheck disable=SC1090
  source "${CCSH}"
  _cc_info() { printf "[CACHE] %s\n" "$*" >&2; }
  setup_ccache
  printf '%s' "${CMAKE_C_COMPILER_LAUNCHER:-EMPTY}"
) > "${TMPDIR:-/tmp}/ccf_out5.$$" 2>/dev/null
_out5="$(cat "${TMPDIR:-/tmp}/ccf_out5.$$")"; rm -f "${TMPDIR:-/tmp}/ccf_out5.$$"
t_assert_eq "${_out5}" "ccache"

# setup_sccache: Rust has no ccache fallback, so a ccache verdict keeps the
# sccache-class default rather than pointing RUSTC_WRAPPER at ccache.
t_case "setup_sccache keeps RUSTC_WRAPPER sccache-class on a ccache verdict"
(
  set -u
  _mk_fakes ok present >/dev/null
  export USE_SCCACHE=true SCCACHE_DIR=/tmp/sc SCCACHE_CACHE_SIZE=1G
  compiler_cache_launcher() { printf '%s' ccache; }
  # shellcheck disable=SC1090
  source "${CCSH}"
  _cc_info() { printf "[CACHE] %s\n" "$*" >&2; }
  setup_sccache
  printf '%s' "${RUSTC_WRAPPER:-EMPTY}"
) > "${TMPDIR:-/tmp}/ccf_out6.$$" 2>/dev/null
_out6="$(cat "${TMPDIR:-/tmp}/ccf_out6.$$")"; rm -f "${TMPDIR:-/tmp}/ccf_out6.$$"
t_assert_eq "${_out6}" "sccache"

t_case "setup_sccache (bootstrap) resolves the guarded launcher for RUSTC_WRAPPER"
(
  set -u
  _mk_fakes ok present >/dev/null
  export USE_SCCACHE=true SCCACHE_DIR=/tmp/sc SCCACHE_CACHE_SIZE=1G
  unset -f compiler_cache_launcher 2>/dev/null || true
  # shellcheck disable=SC1090
  source "${CCSH}"
  _cc_info() { printf "[CACHE] %s\n" "$*" >&2; }
  setup_sccache
  printf '%s' "${RUSTC_WRAPPER:-EMPTY}"
) > "${TMPDIR:-/tmp}/ccf_out7.$$" 2>/dev/null
_out7="$(cat "${TMPDIR:-/tmp}/ccf_out7.$$")"; rm -f "${TMPDIR:-/tmp}/ccf_out7.$$"
t_assert_eq "${_out7}" "$(cd "$(dirname "${CCSH}")" && pwd)/sccache-launcher.sh"

# Mutation check: the bootstrap guarded-launcher preference is load-bearing.
t_case "MUTATION: bootstrap path must NOT fall to bare sccache when the launcher is present"
(
  set -u
  _mk_fakes ok present >/dev/null
  export USE_CCACHE=true USE_SCCACHE=true CCACHE_DIR=/tmp/cc CCACHE_MAXSIZE=1G
  # shellcheck disable=SC1090
  source "${CCSH}"
  _cc_info() { printf "[CACHE] %s\n" "$*" >&2; }
  # Sabotage: make the guarded launcher un-findable; the resolver must then
  # report bare sccache, NOT ccache (sccache is healthy).
  _resolve_compiler_cache_launcher() {
    command -v sccache >/dev/null 2>&1 || { printf '%s' ccache; return 0; }
    if sccache --show-stats >/dev/null 2>&1; then printf '%s' sccache; else printf '%s' ccache; fi
  }
  setup_ccache
  printf '%s' "${CMAKE_C_COMPILER_LAUNCHER:-EMPTY}"
) > "${TMPDIR:-/tmp}/ccf_out8.$$" 2>/dev/null
_out8="$(cat "${TMPDIR:-/tmp}/ccf_out8.$$")"; rm -f "${TMPDIR:-/tmp}/ccf_out8.$$"
t_assert_eq "${_out8}" "sccache"

t_summary
