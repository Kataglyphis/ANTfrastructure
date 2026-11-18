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

# A lockfile as cargo writes it, CRLF as a Windows checkout leaves it: the crate's name line, then its version line.
printf '%s\r\n' '[[package]]' 'name = "js-sys"' 'version = "0.3.77"' '' '[[package]]' 'name = "wasm-bindgen"' 'version = "0.2.100"' \
  'source = "registry+https://github.com/rust-lang/crates.io-index"' '' '[[package]]' 'name = "wasm-bindgen-backend"' 'version = "0.2.99"' > "${_work}/Cargo.lock"
printf '%s\n' '[[package]]' 'name = "js-sys"' 'version = "0.3.77"' > "${_work}/no-bindgen.lock"
# wasm-bindgen reports the version a stub cargo install last wrote, or is absent before any.
lc_stub wasm-bindgen "[ -f $(printf '%q' "${_work}/installed") ] || exit 127; printf 'wasm-bindgen %s\n' \"\$(cat $(printf '%q' "${_work}/installed"))\""
lc_stub cargo "s=$(lc_status cargo); [ \"\${s}\" = 0 ] && printf '%s\n' \"\$5\" > $(printf '%q' "${_work}/installed"); exit \"\${s}\""

t_case "wasm_bindgen_lock_version reads the wasm-bindgen crate's version out of a CRLF lockfile"
lc_call out rc "${RUST}" 'wasm_bindgen_lock_version Cargo.lock'
t_assert_eq "0.2.100" "${out}"
lc_call out rc "${RUST}" 'wasm_bindgen_lock_version no-bindgen.lock'
t_assert_eq "" "${out}" "a lock without the crate yields nothing"

t_case "without a wasm-bindgen on PATH, ensure_wasm_bindgen installs the locked version and checks it runs"
lc_reset
lc_call out rc "${RUST}" 'ensure_wasm_bindgen Cargo.lock'
t_assert_eq "0" "${rc}"
t_assert_eq $'wasm-bindgen --version\ncargo install --locked wasm-bindgen-cli --version 0.2.100\nwasm-bindgen --version' "$(lc_argv)"
t_assert_contains "${out}" "installing wasm-bindgen-cli 0.2.100 for Cargo.lock (PATH has: none)"

t_case "the locked version already on PATH installs nothing; another version is replaced"
lc_reset
lc_call out rc "${RUST}" 'ensure_wasm_bindgen Cargo.lock'
t_assert_eq "0" "${rc}"
t_assert_eq "wasm-bindgen --version" "$(lc_argv)"
t_assert_contains "${out}" "wasm-bindgen 0.2.100 already on PATH"
printf '0.2.99\n' > "${_work}/installed"
lc_reset
lc_call out rc "${RUST}" 'ensure_wasm_bindgen Cargo.lock'
t_assert_eq "0" "${rc}"
t_assert_contains "$(lc_argv)" "cargo install --locked wasm-bindgen-cli --version 0.2.100"
t_assert_contains "${out}" "(PATH has: 0.2.99)"

t_case "a failed install returns cargo's status; an install PATH does not run returns 1"
printf '0.2.99\n' > "${_work}/installed"
lc_fail cargo 101
lc_call out rc "${RUST}" 'ensure_wasm_bindgen Cargo.lock'
t_assert_eq "101" "${rc}"
lc_pass cargo
lc_stub cargo 'exit 0'
lc_call out rc "${RUST}" 'ensure_wasm_bindgen Cargo.lock'
t_assert_eq "1" "${rc}"
t_assert_contains "${out}" "cargo installed wasm-bindgen 0.2.100 into"
t_assert_contains "${out}" "but PATH runs 0.2.99"

t_case "no lockfile, or none naming wasm-bindgen, cannot pin the CLI: 1 and nothing installed"
lc_reset
lc_call out rc "${RUST}" 'ensure_wasm_bindgen no-bindgen.lock'
t_assert_eq "1" "${rc}"
t_assert_contains "${out}" "no wasm-bindgen in no-bindgen.lock: wasm-bindgen-cli cannot be pinned"
lc_call out rc "${RUST}" 'ensure_wasm_bindgen missing.lock'
t_assert_eq "1" "${rc}"
t_assert_contains "${out}" "ensure_wasm_bindgen: no Cargo.lock at 'missing.lock'"
t_assert_eq "" "$(lc_argv)"

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
