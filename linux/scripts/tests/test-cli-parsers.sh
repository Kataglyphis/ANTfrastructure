#!/usr/bin/env bash
# Tests for cli-parsers.sh: an empty or swallowed flag value must fail, not fall back to every arch.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
source "${TESTS_DIR}/../01-core/cli-parsers.sh"

# Stands in for parse_shared_orchestrator_args: the guard works on the (flag, value) tail.
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

# O5: an inert shared flag warns by name (rc 0); a supported one stays silent (rc 1).
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

t_case "both public parsers share architecture aliases, mirrors, globals and help"
for parser_kind in orchestrator runtime; do
  _mode='' _base='' _package='' _wrapper='' _app='' _intermediate=0
  if [ "${parser_kind}" = orchestrator ]; then
    parser_call=(parse_shared_orchestrator_args _ta _uf _fu _fp _ir _vv _pu)
  else
    parser_call=(parse_shared_runtime_args _ta _ir _mode _base _package _wrapper _app _uf _fu _fp _intermediate)
  fi
  for flag in --architectures --target-arches; do
    _ta=unchanged
    _rc=0
    "${parser_call[@]}" "${flag}" arm64,riscv64 || _rc=$?
    t_assert_eq 2 "${_rc}"
    t_assert_eq arm64,riscv64 "${_ta}"
  done
  for flag in --fast-ubuntu-mirror-url --fast-ubuntu-ports-mirror-url; do
    _uf=false _fu=old-ubuntu _fp=old-ports
    _rc=0
    "${parser_call[@]}" "${flag}" 'https://fixture.invalid/path with spaces' || _rc=$?
    t_assert_eq 2 "${_rc}"
    t_assert_eq true "${_uf}"
    if [ "${flag}" = --fast-ubuntu-mirror-url ]; then
      t_assert_eq 'https://fixture.invalid/path with spaces' "${_fu}"
      t_assert_eq old-ports "${_fp}"
    else
      t_assert_eq old-ubuntu "${_fu}"
      t_assert_eq 'https://fixture.invalid/path with spaces' "${_fp}"
    fi
  done
  _uf=false
  _rc=0
  "${parser_call[@]}" --fast-ubuntu-mirror '' || _rc=$?
  t_assert_eq 1 "${_rc}"
  t_assert_eq true "${_uf}"
  for flag in --dry-run --parallel-archs --max-parallel-archs; do
    DRY_RUN=0 PARALLEL_ARCHS=0 MAX_PARALLEL_ARCHS=0
    _rc=0
    "${parser_call[@]}" "${flag}" 3 || _rc=$?
    case "${flag}" in
      --dry-run) t_assert_eq 1 "${_rc}"; t_assert_eq 1 "${DRY_RUN}" ;;
      --parallel-archs) t_assert_eq 1 "${_rc}"; t_assert_eq 1 "${PARALLEL_ARCHS}" ;;
      --max-parallel-archs) t_assert_eq 2 "${_rc}"; t_assert_eq 3 "${MAX_PARALLEL_ARCHS}" ;;
    esac
  done
  for flag in -h --help; do
    _rc=0
    "${parser_call[@]}" "${flag}" '' || _rc=$?
    t_assert_eq 255 "${_rc}"
  done
  _ta=unchanged
  _rc=0
  "${parser_call[@]}" --unknown '' || _rc=$?
  t_assert_eq 0 "${_rc}"
  t_assert_eq unchanged "${_ta}"
  t_assert_fails dispatch_parsed_args "${parser_call[@]}" --target-arches ''
  t_assert_fails dispatch_parsed_args "${parser_call[@]}" --target-arches --push
  t_assert_fails dispatch_parsed_args "${parser_call[@]}" --fast-ubuntu-mirror-url ''
done

t_case "project-specific options retain their destinations and return codes"
_rc=0
parse_shared_orchestrator_args _ta _uf _fu _fp _ir _vv _pu --image-repo fixture/repo || _rc=$?
t_assert_eq 2 "${_rc}"
t_assert_eq fixture/repo "${_ir}"
_rc=0
parse_shared_runtime_args _ta _ir _mode _base _package _wrapper _app _uf _fu _fp _intermediate --torch-dockerfile 'fixture Dockerfile' || _rc=$?
t_assert_eq 2 "${_rc}"
t_assert_eq 'fixture Dockerfile' "${_wrapper}"

t_summary
