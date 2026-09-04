#!/usr/bin/env bash
# CROSS_GCC_TOOLCHAIN_PATH: the operator override 01-core/cross-gcc.sh points clang
# at with --gcc-toolchain. Renamed 2026-09-04 from MYPROJECT_GCC_TOOLCHAIN_PATH, so
# the old name must now resolve to nothing and the new one must stay registered.
# docs/linux-cross-builds.md#operational-env-knobs-not-versionsenv
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SCRIPTS_DIR="$(cd "${TESTS_DIR}/.." && pwd)"
SUBJECT="${SCRIPTS_DIR}/01-core/cross-gcc.sh"
ALLOW="${SCRIPTS_DIR}/lint-env-knobs.allow"
KNOB=CROSS_GCC_TOOLCHAIN_PATH
OLD=MYPROJECT_GCC_TOOLCHAIN_PATH
ABSENT=0.0.0-no-such-toolchain

_root="$(mktemp -d)"
trap 'rm -rf "${_root}"' EXIT

# _probe out|err <VAR=value>... -> the exported CFLAGS, or the resolver's message
_probe() {
  local want="$1"; shift
  (
    # shellcheck disable=SC2163
    export CC=clang "$@"
    # shellcheck source=../01-core/cross-gcc.sh
    . "${SUBJECT}"
    if [ "${want}" = err ]; then export_clang_gcc_toolchain_env 2>&1; return 0; fi
    export_clang_gcc_toolchain_env 2>/dev/null
    printf '%s' "${CFLAGS:-}"
  )
}

t_case "the knob names the GCC root clang is pointed at"
t_assert_contains "$(_probe out "${KNOB}=${_root}")" "--gcc-toolchain=${_root}" \
  "an operator root that exists lands in CFLAGS"
t_assert_contains "$(_probe err "${KNOB}=${_root}/gone")" "no GCC toolchain at ${_root}/gone" \
  "and one that does not exist is named back, not silently replaced"

t_case "unset, the knob defaults to gcc_toolchain_prefix"
t_assert_contains "$(_probe err "GCC_VERSION=${ABSENT}")" "/opt/gcc-${ABSENT}" \
  "the default is /opt/gcc-\$GCC_VERSION, not a hardcoded path"

t_case "the pre-rename name is read nowhere any more"
t_assert_contains "$(_probe err "GCC_VERSION=${ABSENT}" "${OLD}=${_root}")" "/opt/gcc-${ABSENT}" \
  "${OLD} must not win over the default"
t_assert_eq "0" "$(grep -cF -e "${OLD}" "${SUBJECT}")" "no reader of the old name is left"
t_assert_eq "0" "$(grep -cF -e "${OLD}" "${ALLOW}")" "and no registry row under it either"

t_case "the reader owns the knob, so the registry carries no row for it"
t_assert_eq "1" "$(grep -cF -e ": \"\${${KNOB}:=" "${SUBJECT}")" \
  "the self-defaulting form is what makes the default greppable where it is read"
t_assert_eq "0" "$(grep -cF -e "${KNOB}" "${ALLOW}")" "an owned knob needs no lint-env-knobs.allow row"

t_summary
