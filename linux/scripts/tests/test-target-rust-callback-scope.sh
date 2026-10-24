#!/usr/bin/env bash
# Actual cargo callers and stubbed providers cover callback scope, not Rust builds or compiler-wrapper execution.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
_rust_scope_work="$(mktemp -d)"
trap 'rm -rf "${_rust_scope_work}"' EXIT
_rust_scope_owner="${1:-${TESTS_DIR}/../01-core/cross-env.sh}"
t_fn_src "${_rust_scope_owner}" cross_collect_target_rust_env > "${_rust_scope_work}/collector" || exit 1
t_fn_src "${TESTS_DIR}/../03-media/build/gstreamer/common/build-gst-plugins-rs.sh" \
  _gst_rs_riscv_cargo_config > "${_rust_scope_work}/rs" || exit 1
t_fn_src "${TESTS_DIR}/../03-media/build/gstreamer/common/setup-gstreamer.sh" \
  _gst_prepare_target_cargo_env > "${_rust_scope_work}/setup" || exit 1
t_fn_src "${TESTS_DIR}/../03-media/build/gstreamer/common/setup-gstreamer.sh" \
  _gst_target_resolver_available >> "${_rust_scope_work}/setup" || exit 1
t_fn_src "${TESTS_DIR}/../03-media/build/gstreamer/common/setup-gstreamer.sh" \
  _gst_target_publish >> "${_rust_scope_work}/setup" || exit 1
t_fn_src "${TESTS_DIR}/../03-media/build/gstreamer/common/setup-gstreamer.sh" \
  _gst_target_prepare_publish >> "${_rust_scope_work}/setup" || exit 1
t_fn_src "${TESTS_DIR}/../01-core/compiler-resolution.sh" \
  cargo_target_pipeline > "${_rust_scope_work}/pipeline" || exit 1
t_fn_src "${TESTS_DIR}/../01-core/compiler-resolution.sh" \
  cargo_resolved_compiler_field >> "${_rust_scope_work}/pipeline" || exit 1
cat > "${_rust_scope_work}/worker" <<'WORKER'
set -euo pipefail
source "$1/collector"
source "$1/rs"
source "$1/setup"
source "$1/pipeline"
trap 'if declare -F _cctre_provider >/dev/null; then printf CALLBACK_LEAK; fi' EXIT
RUST_SCOPE_WORK="$1"
output=GLOBAL_OUTPUT field=GLOBAL_FIELD probe=GLOBAL_PROBE
cross_bare_bin_path() { printf '%s/nonexistent' "$RUST_SCOPE_WORK"; }
cross_target_upper_rust() { printf '%s_%s_%s' "$output" "$field" "$probe"; }
cross_target_lower_rust() { printf '%s_%s_%s' "$output" "$field" "$probe"; }
cargo_target_rust_env='' cargo_target_rust_lower='' cargo_target_cc_wrapper='' cargo_target_cxx_wrapper=''
CARGO_BUILD_TARGET=riscv64-linux
case "$2" in
  global) _gst_rs_riscv_cargo_config ;;
  local)
    invoke_local() {
      local output=LOCAL_OUTPUT field=LOCAL_FIELD probe=LOCAL_PROBE
      _gst_rs_riscv_cargo_config
    }
    invoke_local
    ;;
  array)
    unset "$3"
    declare -A "$3"
    declare -n observed="$3"
    observed[upper]=before_upper observed[lower]=before_lower
    cross_target_upper_rust() { printf UPPER; }
    cross_target_lower_rust() { printf LOWER; }
    cross_collect_target_rust_env "$3"
    printf '%s|%s' "${observed[upper]}" "${observed[lower]}"
    exit
    ;;
  absent)
    unset -f cross_target_upper_rust cross_target_lower_rust
    declare -A observed=([upper]=before_upper [lower]=before_lower)
    cross_collect_target_rust_env observed
    printf '%s|%s' "${observed[upper]}" "${observed[lower]}"
    exit
    ;;
  partial|empty|upper-only|lower-only)
    declare -A observed=([upper]=before_upper [lower]=before_lower)
    cross_target_upper_rust() { printf UPPER; return 23; }
    cross_target_lower_rust() { printf LOWER; return 37; }
    case "$2" in
      empty)
        cross_target_upper_rust() { return 23; }
        cross_target_lower_rust() { return 37; }
        ;;
      upper-only) unset -f cross_target_lower_rust ;;
      lower-only) unset -f cross_target_upper_rust ;;
    esac
    cross_collect_target_rust_env observed
    printf '%s|%s' "${observed[upper]}" "${observed[lower]}"
    exit
    ;;
  order)
    declare -A observed=([upper]=before_upper [lower]=before_lower)
    command() { printf 'LOOKUP:%s\n' "$*" >> "$RUST_SCOPE_WORK/order"; builtin command "$@"; }
    cross_target_upper_rust() { printf 'PROBE:upper\n' >> "$RUST_SCOPE_WORK/order"; printf UPPER; }
    cross_target_lower_rust() { printf 'PROBE:lower:%s\n' "${observed[upper]}" >> "$RUST_SCOPE_WORK/order"; printf LOWER; }
    cross_collect_target_rust_env observed
    cat "$RUST_SCOPE_WORK/order"
    exit
    ;;
  alias)
    shopt -s expand_aliases
    unset -f cross_target_upper_rust cross_target_lower_rust
    alias_upper_first() { printf FIRST_UPPER; }
    alias_lower_first() { printf first_lower; }
    alias_upper() { printf ALIAS_UPPER; }
    alias_lower() { printf aliased_lower; }
    select_aliases() {
      alias cross_target_upper_rust=alias_upper
      alias cross_target_lower_rust=alias_lower
    }
    alias cross_target_upper_rust=alias_upper_first
    alias cross_target_lower_rust=alias_lower_first
    [ "$3" != before ] || select_aliases
    if [ "$4" = helper-first ]; then source "$1/collector"; else source "$1/$5"; fi
    [ "$3" != between ] || select_aliases
    if [ "$4" = helper-first ]; then source "$1/$5"; else source "$1/collector"; fi
    [ "$3" != after ] || select_aliases
    if [ "$5" = rs ]; then
      _gst_rs_riscv_cargo_config
      printf '%s\n%s' "$cargo_target_rust_env" "$cargo_target_rust_lower"
    else
      cross_target_arch() { printf riscv64; }
      resolve_cross_cc_cxx_for_arch() { CC=/target/cc CXX=/target/cxx; }
      export_cargo_target_linker() { printf 'LINK:%s|%s|%s|%s\n' "$@"; }
      _gst_prepare_target_cargo_env
    fi
    exit
    ;;
esac
printf '%s\n%s\n' "$cargo_target_rust_env" "$cargo_target_rust_lower"
printf 'ROOT:%s:%s:%s' "$output" "$field" "$probe"
WORKER
for _rust_scope_mode in global local; do
  t_case "actual GStreamer caller preserves ${_rust_scope_mode} callback bindings"
  _rust_scope_expected=GLOBAL_OUTPUT_GLOBAL_FIELD_GLOBAL_PROBE
  [ "${_rust_scope_mode}" != local ] || _rust_scope_expected=LOCAL_OUTPUT_LOCAL_FIELD_LOCAL_PROBE
  _rust_scope_actual="$(bash "${_rust_scope_work}/worker" "${_rust_scope_work}" "${_rust_scope_mode}")"
  t_assert_eq "${_rust_scope_expected}"$'\n'"${_rust_scope_expected}"$'\nROOT:GLOBAL_OUTPUT:GLOBAL_FIELD:GLOBAL_PROBE' "${_rust_scope_actual}"
done
for _rust_scope_name in output field probe; do
  t_case "caller array named ${_rust_scope_name} remains the publication target"
  t_assert_eq 'UPPER|LOWER' "$(bash "${_rust_scope_work}/worker" "${_rust_scope_work}" array "${_rust_scope_name}")"
done
t_case "absent providers leave existing fields unchanged"
t_assert_eq 'before_upper|before_lower' "$(bash "${_rust_scope_work}/worker" "${_rust_scope_work}" absent)"
t_case "failing providers retain their partial stdout"
t_assert_eq 'UPPER|LOWER' "$(bash "${_rust_scope_work}/worker" "${_rust_scope_work}" partial)"
t_case "available empty probes replace seeded fields"
t_assert_eq '|' "$(bash "${_rust_scope_work}/worker" "${_rust_scope_work}" empty)"
t_case "upper-only provider leaves the lower seed unchanged"
t_assert_eq 'UPPER|before_lower' "$(bash "${_rust_scope_work}/worker" "${_rust_scope_work}" upper-only)"
t_case "lower-only provider leaves the upper seed unchanged"
t_assert_eq 'before_upper|LOWER' "$(bash "${_rust_scope_work}/worker" "${_rust_scope_work}" lower-only)"
t_case "ordered probes publish the upper field before invoking the lower hook"
t_assert_eq $'LOOKUP:-v cross_target_upper_rust\nPROBE:upper\nLOOKUP:-v cross_target_lower_rust\nPROBE:lower:UPPER' \
  "$(bash "${_rust_scope_work}/worker" "${_rust_scope_work}" order)"
for _rust_scope_subject in rs setup; do
  _rust_scope_expected=$'ALIAS_UPPER\naliased_lower'
  if [ "${_rust_scope_subject}" = setup ]; then
    _rust_scope_expected=$'LINK:ALIAS_UPPER|aliased_lower|/target/cc|/target/cxx\nCross cargo: target linker /target/cc (CARGO_TARGET_ALIAS_UPPER_LINKER)'
  fi
  for _rust_scope_phase in before between after; do
    for _rust_scope_order in helper-first caller-first; do
      t_case "${_rust_scope_subject} aliases ${_rust_scope_phase} declarations, ${_rust_scope_order}"
      t_assert_eq "${_rust_scope_expected}" "$(bash "${_rust_scope_work}/worker" "${_rust_scope_work}" alias "${_rust_scope_phase}" "${_rust_scope_order}" "${_rust_scope_subject}")"
    done
  done
done
t_case "missing required output preserves nounset failure without any providers"
t_assert_rc 127 bash -uc 'source "$1/collector"; unset -f cross_target_upper_rust cross_target_lower_rust; cross_collect_target_rust_env' _ "${_rust_scope_work}"
t_case "relaxed missing output retains an empty optional probe result"
t_assert_rc 0 bash -c 'source "$1/collector"; unset -f cross_target_upper_rust cross_target_lower_rust; cross_collect_target_rust_env' _ "${_rust_scope_work}"
t_summary
