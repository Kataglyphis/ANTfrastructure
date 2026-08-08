#!/usr/bin/env bash
# Tests for 01-core/cli-parsers.sh — the arg loop behind all six orchestrator
# entry points. Pins the two-arg value guard (a trailing `--target-arches` or
# one that swallowed the NEXT flag used to assign ""/"--push" silently and
# fall through to CROSS_DEFAULT_ARCHES — building all three arches).
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
source "${TESTS_DIR}/../01-core/cli-parsers.sh"

# Minimal two-arg/one-arg parser standing in for parse_shared_orchestrator_args
# (dispatch_parsed_args' guard works on the (flag, value) tail by contract).
_fake_parser() {
  # args: <out_nameref-placeholder> <flag> <value>
  case "$2" in
    --two-arg) return 2 ;;
    --one-arg) return 1 ;;
    *) return 0 ;;
  esac
}

t_case "two-arg flag with real value passes"
t_assert_ok dispatch_parsed_args _fake_parser _x --two-arg somevalue
dispatch_parsed_args _fake_parser _x --two-arg somevalue >/dev/null 2>&1
t_assert_eq "2" "${_DP_SHIFT}"

t_case "two-arg flag with EMPTY value is rejected"
t_assert_fails dispatch_parsed_args _fake_parser _x --two-arg ""

t_case "two-arg flag that swallowed the next flag is rejected"
t_assert_fails dispatch_parsed_args _fake_parser _x --two-arg --push

t_case "one-arg flag unaffected by the guard"
t_assert_ok dispatch_parsed_args _fake_parser _x --one-arg ""
dispatch_parsed_args _fake_parser _x --one-arg "" >/dev/null 2>&1
t_assert_eq "1" "${_DP_SHIFT}"

t_case "unrecognized flag falls through with shift 0"
t_assert_ok dispatch_parsed_args _fake_parser _x --unknown ""
dispatch_parsed_args _fake_parser _x --unknown "" >/dev/null 2>&1
t_assert_eq "0" "${_DP_SHIFT}"

t_case "consume_dp_shift maps shift counts to handled/unhandled"
_DP_SHIFT=2; t_assert_ok consume_dp_shift
_DP_SHIFT=1; t_assert_ok consume_dp_shift
_DP_SHIFT=0; t_assert_fails consume_dp_shift

t_case "real parser: --target-arches with value works end to end"
_ta="" _uf="" _fu="" _fp="" _ir="" _vv="" _pu=0
_rc=0
parse_shared_orchestrator_args _ta _uf _fu _fp _ir _vv _pu \
  --target-arches arm64,riscv64 2>/dev/null || _rc=$?
t_assert_eq "2" "${_rc}" "two-arg flag must return 2"
t_assert_eq "arm64,riscv64" "${_ta}"

t_summary
