#!/usr/bin/env bash
# lib/rust-toolchain.sh and lib/wasm-opt.sh are consumer API with no caller here; these cases pin argv, status and output.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=linux/scripts/tests/lib-contract-fixture.sh
source "${TESTS_DIR}/lib-contract-fixture.sh"
source "${TESTS_DIR}/test-workspace-fixture.sh"
declare _work
t_fixture_workspace_init _work || exit 1
lc_init "${_work}" || exit 1
RUST="${TESTS_DIR}/../lib/rust-toolchain.sh"
WASM="${TESTS_DIR}/../lib/wasm-opt.sh"
declare out rc

t_case "with rustup, ensure_wasm32_target adds the target and returns rustup's status"
lc_stub rustup
lc_call out rc "${RUST}" 'ensure_wasm32_target'
t_assert_eq "0" "${rc}"
t_assert_eq "rustup target add wasm32-unknown-unknown" "$(lc_argv)"
lc_fail rustup 4
lc_call out rc "${RUST}" 'ensure_wasm32_target'
t_assert_eq "4" "${rc}" "a failed rustup is the caller's to judge"

t_case "without rustup, an installed wasm32 std is enough"
rm -f "${_work}/bin/rustup"
mkdir -p "${_work}/sysroot/lib/wasm32"
lc_stub rustc "case \"\$*\" in *target-libdir*) printf '%s\n' $(printf '%q' "${_work}/sysroot/lib/wasm32") ;; *sysroot*) printf '/opt/rust\n' ;; esac"
lc_reset
lc_call_bare out rc "${RUST}" ensure_wasm32_target
t_assert_eq "0" "${rc}"
t_assert_eq "rustc --print target-libdir --target wasm32-unknown-unknown" "$(lc_argv)"
t_assert_contains "${out}" "rustup not present; wasm32-unknown-unknown std already installed (${_work}/sysroot/lib/wasm32)"

t_case "without rustup and without the std, it warns with the sysroot and returns 1"
rmdir "${_work}/sysroot/lib/wasm32"
lc_call_bare out rc "${RUST}" ensure_wasm32_target
t_assert_eq "1" "${rc}"
t_assert_contains "${out}" "rustup is not installed AND this toolchain has no wasm32-unknown-unknown std"
t_assert_contains "${out}" "(rustc sysroot: /opt/rust) - cannot build wasm here"

t_case "wasm_opt_optimize passes the level, the feature list, input and output"
lc_stub wasm-opt
lc_reset
lc_call out rc "${WASM}" 'wasm_opt_optimize in.wasm out.wasm -O3'
t_assert_eq "0" "${rc}"
t_assert_eq "wasm-opt -O3 --enable-bulk-memory-opt --enable-nontrapping-float-to-int --enable-simd --enable-sign-ext --enable-reference-types --enable-mutable-globals --enable-multivalue in.wasm -o out.wasm" "$(lc_argv)"
lc_reset
lc_call out rc "${WASM}" 'wasm_opt_optimize in.wasm out.wasm'
t_assert_contains "$(lc_argv)" "wasm-opt -Oz --enable-bulk-memory-opt" "the default level is -Oz"

t_case "a rejected feature list retries once with --all-features, and a second failure is fatal"
lc_stub wasm-opt "case \"\$*\" in *--all-features*) exit $(lc_status all-features) ;; esac; exit 1"
lc_reset
lc_call out rc "${WASM}" 'wasm_opt_optimize in.wasm out.wasm'
t_assert_eq "0" "${rc}"
t_assert_contains "${out}" "wasm-opt with explicit feature flags failed; retrying with --all-features"
t_assert_eq "wasm-opt -Oz --all-features in.wasm -o out.wasm" "$(lc_argv | sed -n 2p)"
lc_fail all-features 1
lc_expect 1 "wasm-opt failed for in.wasm" "${WASM}" 'wasm_opt_optimize in.wasm out.wasm'

t_case "wasm_opt_optimize requires an input and an output"
lc_call out rc "${WASM}" 'wasm_opt_optimize'
t_assert_fails test "${rc}" -eq 0
t_assert_contains "${out}" "input wasm required"
lc_call out rc "${WASM}" 'wasm_opt_optimize in.wasm'
t_assert_contains "${out}" "output wasm required"

t_summary
