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

# ---------------------------------------------------------------------------
# O5: per-script flag allowlist. A shared flag listed in
# ORCHESTRATOR_UNSUPPORTED_FLAGS warns (and reports it warned via rc 0); a
# supported flag stays silent (rc 1). The warning must name the flag and say it
# has no effect, so a user passing an inert --push/--parallel-archs is told.
warn() { printf '[WARN] %s\n' "$*" >&2; }   # stub for orchestrator_warn_if_unsupported

t_case "O5: an inert shared flag warns and returns 0"
ORCHESTRATOR_UNSUPPORTED_FLAGS="--push"
t_assert_ok orchestrator_warn_if_unsupported --push build-cross-chain.sh
_w="$(orchestrator_warn_if_unsupported --push build-cross-chain.sh 2>&1)"
t_assert_contains "${_w}" "--push" "warning must name the flag"
t_assert_contains "${_w}" "no effect" "warning must explain the flag is inert"
t_assert_contains "${_w}" "build-cross-chain.sh" "warning must name the script"

t_case "O5: a supported shared flag stays silent and returns non-zero"
ORCHESTRATOR_UNSUPPORTED_FLAGS="--push"
t_assert_fails orchestrator_warn_if_unsupported --target-arches build-cross-chain.sh
t_assert_eq "" "$(orchestrator_warn_if_unsupported --target-arches x 2>&1)" \
  "a supported flag must not warn"

t_case "O5: multiple inert flags (build-cross-stage) are each caught"
ORCHESTRATOR_UNSUPPORTED_FLAGS="--parallel-archs --max-parallel-archs"
t_assert_ok orchestrator_warn_if_unsupported --parallel-archs build-cross-stage.sh
t_assert_ok orchestrator_warn_if_unsupported --max-parallel-archs build-cross-stage.sh
t_assert_fails orchestrator_warn_if_unsupported --push build-cross-stage.sh

t_case "O5: empty allowlist warns for nothing"
ORCHESTRATOR_UNSUPPORTED_FLAGS=""
t_assert_fails orchestrator_warn_if_unsupported --push x
unset ORCHESTRATOR_UNSUPPORTED_FLAGS

t_summary
