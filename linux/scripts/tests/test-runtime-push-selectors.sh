#!/usr/bin/env bash
# Callback fixtures cover selector effects, order and dynamic locals, not container execution or registry publication.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
source_dir="${1:-${TESTS_DIR}/..}"
receipt="${2:-}"
for entry in artifacts manifest; do
  eval "$(t_fn_src "$source_dir/build-runtime-$entry.sh" "_${entry}_extra_arg")"
done
if grep -q '^orchestrator_consume_runtime_push_arg() {' "$source_dir/lib-orchestrator.sh"; then
  eval "$(t_fn_src "$source_dir/lib-orchestrator.sh" orchestrator_consume_runtime_push_arg)"
fi
[ -z "$receipt" ] || : > "$receipt"

_push_trace_assignment() {
  local statement="$1" name declaration target
  [[ "$statement" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || return 0
  name="${statement%%=*}"
  declaration="$(declare -p "$name" 2>/dev/null || true)"
  if [[ "$declaration" == 'declare -n '* ]]; then
    target="${declaration#*=}"; target="${target#\"}"; name="${target%\"}"
  fi
  case "$name" in
    PUSH_IMAGES|PUSH_MANIFEST|PUSH_INTERMEDIATE_IMAGES|GATES_ONLY|BUILD_IMAGES|CREATE_MANIFEST|_OARG_SHIFT)
      _push_order+="$name=${statement#*=}"$'\n' ;;
  esac
}

_push_expected_step() {
  case "$1:$2" in
    artifacts:--push|manifest:--push-images) printf 'PUSH_IMAGES=1 _OARG_SHIFT=1' ;;
    artifacts:--push-all) printf 'PUSH_IMAGES=1 PUSH_INTERMEDIATE_IMAGES=1 _OARG_SHIFT=1' ;;
    manifest:--push) printf 'PUSH_IMAGES=1 PUSH_MANIFEST=1 _OARG_SHIFT=1' ;;
    manifest:--push-all) printf 'PUSH_IMAGES=1 PUSH_MANIFEST=1 PUSH_INTERMEDIATE_IMAGES=1 _OARG_SHIFT=1' ;;
    manifest:--push-manifest) printf 'PUSH_MANIFEST=1 _OARG_SHIFT=1' ;;
    manifest:--gates-only) printf 'GATES_ONLY=1 BUILD_IMAGES=0 CREATE_MANIFEST=0 _OARG_SHIFT=1' ;;
    *) return 1 ;;
  esac
}

_push_capture() {
  local entry="$1" initial="$2"; shift 2
  local PUSH_IMAGES PUSH_MANIFEST PUSH_INTERMEDIATE_IMAGES GATES_ONLY BUILD_IMAGES CREATE_MANIFEST _OARG_SHIFT
  local field status=0 expected_status=0 step assignment expected_order="" actual="" wanted="" _push_order=""
  local -A expected=()
  local -a fields=(PUSH_IMAGES PUSH_MANIFEST PUSH_INTERMEDIATE_IMAGES GATES_ONLY BUILD_IMAGES CREATE_MANIFEST _OARG_SHIFT)
  for field in "${fields[@]}"; do
    case "$initial" in
      unset) expected[$field]='<unset>' ;;
      zeros) expected[$field]=0 ;;
      sentinels) expected[$field]="$field-before" ;;
    esac
    if [ "$initial" != unset ]; then printf -v "$field" '%s' "${expected[$field]}"; fi
  done
  t_case "$entry $initial $*"
  local argument_list="$*"
  while [ "$#" -gt 0 ]; do
    step=""; expected_status=0
    step="$(_push_expected_step "$entry" "$1")" || expected_status=$?
    for assignment in $step; do
      expected[${assignment%%=*}]="${assignment#*=}"
      expected_order+="$assignment"$'\n'
    done
    set -T
    trap '_push_trace_assignment "$BASH_COMMAND"' DEBUG
    if "_${entry}_extra_arg" "$@"; then status=0; else status=$?; fi
    trap - DEBUG
    set +T
    [ "$status" -eq 0 ] && [ "$expected_status" -eq 0 ] || break
    [ "${_OARG_SHIFT-}" = 1 ] || break
    shift "$_OARG_SHIFT"
  done
  for field in "${fields[@]}"; do
    wanted+="$field=${expected[$field]}"$'\n'
  done
  printf -v actual '%s\n' \
    "PUSH_IMAGES=${PUSH_IMAGES-<unset>}" "PUSH_MANIFEST=${PUSH_MANIFEST-<unset>}" \
    "PUSH_INTERMEDIATE_IMAGES=${PUSH_INTERMEDIATE_IMAGES-<unset>}" "GATES_ONLY=${GATES_ONLY-<unset>}" \
    "BUILD_IMAGES=${BUILD_IMAGES-<unset>}" "CREATE_MANIFEST=${CREATE_MANIFEST-<unset>}" "_OARG_SHIFT=${_OARG_SHIFT-<unset>}"
  t_assert_eq "$expected_status" "$status"
  t_assert_eq "$wanted" "$actual"
  t_assert_eq "$expected_order" "$_push_order"
  t_record_fixture_receipt "$receipt" "$entry" "$initial" "$argument_list" "$status" "$actual" "$_push_order"
}

for entry in artifacts manifest; do
  for initial in unset zeros sentinels; do
    for flag in --push --push-all --push-images --push-manifest --gates-only --unknown; do
      _push_capture "$entry" "$initial" "$flag"
    done
    for flag in --push --push-all --push-images --push-manifest; do
      _push_capture "$entry" "$initial" --gates-only "$flag"
      _push_capture "$entry" "$initial" "$flag" --gates-only
    done
  done
done
t_summary
