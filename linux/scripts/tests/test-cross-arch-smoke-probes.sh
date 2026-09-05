#!/usr/bin/env bash
# smoke-cross-all-arches.sh's five probe sections, driven one at a time. The
# clang sweep is the reason this suite exists: it reports on ONE default triple
# and used to break after the first arch, so a wrong -dumpmachine passed
# silently. docs/cross-build-verification.md#cross-compiler-multi-arch-smoke
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
PKG="${TESTS_DIR}/../06-packaging"
SMOKE="${PKG}/smoke-cross-all-arches.sh"

t_case "the sandbox trick still holds: main() is invoked on the LAST line"
t_assert_eq 'main "$@"' "$(tail -1 "${SMOKE}")"

_SB="$(mktemp -d)"
trap 'rm -rf "${_SB}"' EXIT
sed '$d' "${SMOKE}" > "${_SB}/probe.sh"
cp "${PKG}/smoke-common.sh" "${_SB}/"
mkdir -p "${_SB}/bin"

# One probe run against the real pass/fail vocabulary from smoke-common.sh.
_probe() {
  bash -c "source '${_SB}/probe.sh' >/dev/null 2>&1
    FAILURES=0
    $1
    printf 'FAILURES=%s\n' \"\${FAILURES}\"" 2>&1
}

_fake_clang() {
  printf '#!/bin/sh\nprintf "%%s\\n" "%s"\n' "$1" > "${_SB}/bin/clang"
  chmod +x "${_SB}/bin/clang"
}

# ── the clang sweep ─────────────────────────────────────────────────────
t_case "a triple matching a requested arch PASSES and names that arch"
_fake_clang "aarch64-unknown-linux-gnu"
_out="$(SMOKE_TARGET_CLANG="${_SB}/bin/clang" _probe '_smoke_probe_llvm_target_clang amd64,arm64,riscv64')"
t_assert_contains "${_out}" "PASS clang (llvm-target)"
t_assert_contains "${_out}" "(matches arm64)"
t_assert_contains "${_out}" "FAILURES=0"

t_case "the sweep does not stop at the first arch — a LAST-listed match still passes"
_fake_clang "riscv64-unknown-linux-gnu"
_out="$(SMOKE_TARGET_CLANG="${_SB}/bin/clang" _probe '_smoke_probe_llvm_target_clang amd64,arm64,riscv64')"
t_assert_contains "${_out}" "(matches riscv64)" "breaking after arch #1 is the historical bug"
t_assert_contains "${_out}" "FAILURES=0"

t_case "a triple matching NONE of the requested arches FAILS, and says so"
_fake_clang "riscv64-unknown-linux-gnu"
_out="$(SMOKE_TARGET_CLANG="${_SB}/bin/clang" _probe '_smoke_probe_llvm_target_clang amd64,arm64')"
t_assert_contains "${_out}" "matches none of: amd64,arm64"
t_assert_contains "${_out}" "FAILURES=1" "a wrong target clang must be a failure, not a silent skip"

t_case "a clang that prints nothing is EMPTY and still fails"
_fake_clang ""
_out="$(SMOKE_TARGET_CLANG="${_SB}/bin/clang" _probe '_smoke_probe_llvm_target_clang amd64,arm64,riscv64')"
t_assert_contains "${_out}" "-dumpmachine=EMPTY"
t_assert_contains "${_out}" "FAILURES=1"

t_case "no target clang at all: the section is skipped, and skipping is not a failure"
_out="$(SMOKE_TARGET_CLANG="${_SB}/bin/absent" _probe '_smoke_probe_llvm_target_clang amd64,arm64,riscv64')"
t_assert_eq "FAILURES=0" "${_out}" "images without llvm-target must print no clang section at all"

t_case "the matcher itself: prefix match per arch, empty when none, empty on empty input"
_match() { _probe "printf '[%s]' \"\$(_smoke_clang_match_arch $1)\""; }
t_assert_contains "$(_match 'x86_64-pc-linux-gnu amd64,arm64,riscv64')" "[amd64]"
t_assert_contains "$(_match 'wasm32-unknown-unknown amd64,arm64,riscv64')" "[]" "an unknown triple must match nothing, not the first arch"
t_assert_contains "$(_match '"" amd64,arm64,riscv64')" "[]"

# ── the cross-compiler sweep ────────────────────────────────────────────
t_case "the host arch is skipped and every other requested arch is probed"
_out="$(GCC_PREFIX="${_SB}/nogcc" _probe '_smoke_probe_cross_compilers amd64,arm64,riscv64 amd64')"
t_assert_contains "${_out}" "Cross GCC for arm64 not found"
t_assert_contains "${_out}" "Cross GCC for riscv64 not found"
t_assert_eq "2" "$(printf '%s\n' "${_out}" | grep -c 'Cross GCC for')" "the host arch must not be cross-probed"
t_assert_contains "${_out}" "FAILURES=2" "a missing cross GCC is a failure, one per arch"

t_case "an unmappable arch name is reported once and does not abort the sweep"
_out="$(GCC_PREFIX="${_SB}/nogcc" _probe '_smoke_probe_cross_compilers nonesuch,arm64 amd64')"
t_assert_contains "${_out}" "Cannot determine triplet for nonesuch"
t_assert_contains "${_out}" "Cross GCC for arm64 not found" "the arch after the bad one must still be probed"

# ── the symlink chain ───────────────────────────────────────────────────
t_case "every tool in the chain gets its own verdict"
_out="$(_probe '_smoke_probe_symlink_chain')"
for _t in cc c++ gcc g++; do
  t_assert_contains "${_out}" " ${_t} " "no verdict printed for ${_t}"
done

t_case "a tool missing from PATH FAILS instead of printing an empty target"
_out="$(_probe 'PATH="'"${_SB}"'/empty"; _smoke_probe_symlink_chain')"
t_assert_contains "${_out}" "cc not found in PATH"
t_assert_contains "${_out}" "FAILURES=4"

# ── the split itself ────────────────────────────────────────────────────
t_case "main still runs all four probes — a dropped call silently retires a whole toolchain check"
_main="$(t_fn_src "${SMOKE}" main)"
for _p in _smoke_probe_host_compilers _smoke_probe_cross_compilers \
          _smoke_probe_llvm_target_clang _smoke_probe_symlink_chain; do
  t_assert_contains "${_main}" "${_p}" "main no longer calls ${_p}"
done
t_assert_contains "${_main}" "smoke_summary" "without the summary the smoke exits 0 on any number of failures"

t_summary
