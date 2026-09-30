#!/usr/bin/env bash
# The tarball comes from a mirror but its proofs only from gcc.gnu.org; see docs/failure-modes.md#a-checksum-probe-that-cannot-reach-the-server-reads-as-nothing-to-verify
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
BUILD_GCC="${TESTS_DIR}/../02-toolchain/build-gcc.sh"

# build-gcc.sh is a top-level script, so its helpers are extracted rather than sourced.
_lib="$(mktemp)"; trap 'rm -f "${_lib}"' EXIT
for _fn in _gcc_probe_url _gcc_sha_unverified_or_die verify_gcc_sha512 _gcc_gpg_require_or_warn; do
  awk -v f="${_fn}" '$0 ~ "^"f"\\(\\) \\{" {p=1} p {print} p && /^\}/ {exit}' \
    "${BUILD_GCC}" >> "${_lib}"
done

# _verify_run <fn> [env..]: one extracted helper with wget stubbed as unreachable.
_verify_run() {
  local _fn="$1"; shift
  env "$@" bash -c '
    set -u
    wget() { return 4; }   # 4 = network failure, not "404 absent"
    SHA_URL=x; SIG_URL=y; TARBALL=t
    source "'"${_lib}"'"
    '"${_fn}" 2>&1
}

t_case "an unreachable checksum host aborts by default"
_out="$(_verify_run verify_gcc_sha512 GCC_ALLOW_UNVERIFIED_TARBALL=0)"
t_assert_eq "1" "$?" "a tarball that cannot be verified must not be built"
t_assert_contains "${_out}" "refusing to build an unverified GCC tarball" \
  "the abort must say what it is refusing and why"

t_case "the operator can accept the trade deliberately"
_verify_run verify_gcc_sha512 GCC_ALLOW_UNVERIFIED_TARBALL=1 >/dev/null
t_assert_eq "0" "$?" "GCC_ALLOW_UNVERIFIED_TARBALL=1 must continue, loudly"

t_case "GCC_REQUIRE_GPG covers the unreachable-signature case too"
# REQUIRE_GPG must also cover a signature that could not be fetched.
_verify_run _gcc_gpg_require_or_warn GCC_REQUIRE_GPG=1 >/dev/null
t_assert_eq "1" "$?" "REQUIRE_GPG=1 must abort when verification was skipped"
_verify_run _gcc_gpg_require_or_warn GCC_REQUIRE_GPG=0 >/dev/null
t_assert_eq "0" "$?" "the default stays a warning"

t_case "the signature probe routes through the require policy"
_sig_block="$(awk '/^verify_gcc_gpg_signature\(\) \{/,/^\}/' "${BUILD_GCC}")"
_probe_tail="$(printf '%s\n' "${_sig_block}" | grep -A6 -e '_gcc_probe_url "${SIG_URL}"')"
t_assert_contains "${_probe_tail}" "_gcc_gpg_require_or_warn" \
  "an unanswered .sig probe must obey GCC_REQUIRE_GPG, not return 0 silently"

t_summary
