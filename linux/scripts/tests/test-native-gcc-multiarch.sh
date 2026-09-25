#!/usr/bin/env bash
# The Canadian native GCC (host == target) is configured with --enable-multiarch, and the swap
# refuses a relocated GCC that prints another multiarch where it can run it. build-gcc.sh is
# top-level, so its configure region runs with the command array printed, never executed.
# NOT covered: what GCC's configure makes of the flag -- only a Linux chain run shows that.
# docs/cross-build-verification.md#the-native-gcc-has-multiarch
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
BUILD_GCC="${TESTS_DIR}/../02-toolchain/build-gcc.sh"
SWAP="${TESTS_DIR}/../06-packaging/swap-native-gcc.sh"

_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT

# ── build-gcc.sh: the configure line each GCC gets ───────────────────────────
# From the shared predicate through the end of the target block, run with CONFIG_CMD printed
# one word per line: an empty word would show as an empty line.
awk '/^_gcc_is_canadian_native\(\) \{$/{p=1} p{print} p && /^fi$/{exit}' "${BUILD_GCC}" > "${_work}/configure.sh"
_configure_for() {  # <host> <target> -> the configure words, one per line
  env HOST_TRIPLET="$1" TARGET_TRIPLET="$2" SYSROOT=/ NATIVE_SYSTEM_HEADER_DIR="/usr/$2/include" bash -c '
    set -euo pipefail; CONFIG_CMD=(); source "$1"; printf "%s\n" "${CONFIG_CMD[@]}"' _ "${_work}/configure.sh"
}
_multiarch_words() { printf '%s\n' "$(_configure_for "$1" "$2")" | grep -c -e '--enable-multiarch'; }

t_case "the Canadian native's configure line asks for multiarch (the half-fix trap)"
_out="$(_configure_for aarch64-linux-gnu aarch64-linux-gnu)"
t_assert_contains "${_out}" "--enable-multiarch" "defined but not wired changes nothing"
t_assert_contains "${_out}" "--with-native-system-header-dir=/usr/aarch64-linux-gnu/include" \
  "the flag that switches GCC's auto-check off, the reason this one is explicit"
t_assert_eq "1" "$(_multiarch_words riscv64-linux-gnu riscv64-linux-gnu)" "the riscv64 image's cc"

t_case "no other GCC's configure line changes, and none gains an empty word"
t_assert_eq "0" "$(_multiarch_words "" aarch64-linux-gnu)" "a plain cross keeps its cross layout"
t_assert_eq "0" "$(_multiarch_words x86_64-linux-gnu aarch64-linux-gnu)" "a Canadian with host != target"
t_assert_eq "0" "$(_multiarch_words "" "")" "the full make never reaches the target block"
t_assert_eq "0" "$(_configure_for "" aarch64-linux-gnu | grep -c '^$')" "an unset helper result is no word at all"

# ── swap-native-gcc.sh: the relocated GCC's multiarch ────────────────────────
_swap_fn="$(t_fn_src "${SWAP}" _assert_native_gcc_multiarch)" || exit 1
_fake_gcc() {  # <path> <multiarch> | <path> --no-exec: a gcc answering the two questions asked
  if [ "$2" = --no-exec ]; then printf '#!/bin/sh\nexit 126\n' > "$1"; else
    printf '#!/bin/sh\ncase "$1" in -dumpversion) echo 16.2.0 ;; -print-multiarch) echo "%s" ;; esac\n' "$2" > "$1"
  fi
  chmod +x "$1"
}
_ma_check() { bash -c 'set -euo pipefail; eval "$1"; _assert_native_gcc_multiarch "$2" "$3"' _ "${_swap_fn}" "$1" "$2"; }

t_case "a GCC that prints the image's triplet passes"
_fake_gcc "${_work}/ok-gcc" aarch64-linux-gnu
t_assert_ok _ma_check "${_work}/ok-gcc" aarch64-linux-gnu
t_assert_contains "$(t_out _ma_check "${_work}/ok-gcc" aarch64-linux-gnu)" "Native GCC multiarch: aarch64-linux-gnu"

t_case "no multiarch, or another triplet, fails and says which"
_fake_gcc "${_work}/none-gcc" ""
t_assert_fails _ma_check "${_work}/none-gcc" aarch64-linux-gnu
t_assert_contains "$(t_out _ma_check "${_work}/none-gcc" aarch64-linux-gnu)" "prints '', not 'aarch64-linux-gnu'" \
  "the defect itself: the arm64 image's cc before the fix"
_fake_gcc "${_work}/amd64-gcc" x86_64-linux-gnu
t_assert_fails _ma_check "${_work}/amd64-gcc" aarch64-linux-gnu

t_case "a GCC this host cannot run is noted, not failed (the smoke's own tolerance)"
_fake_gcc "${_work}/foreign-gcc" --no-exec
t_assert_ok _ma_check "${_work}/foreign-gcc" aarch64-linux-gnu
t_assert_contains "$(t_out _ma_check "${_work}/foreign-gcc" aarch64-linux-gnu)" "multiarch is not checked here"

t_case "main() asks it of the relocated GCC -- a gate nothing invokes is not a gate"
t_assert_contains "$(t_fn_src "${SWAP}" main)" \
  '_assert_native_gcc_multiarch "/opt/gcc-${GCC_VERSION}/bin/gcc" "${triplet}"'

t_summary
