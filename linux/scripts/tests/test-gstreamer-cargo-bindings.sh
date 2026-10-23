#!/usr/bin/env bash
# Cargo receipts cover compiler bindings and isolated resolver status, not real wrappers, Rust builds or ABI compatibility.
set -euo pipefail
# shellcheck source=linux/scripts/tests/media-probe-fixture.sh
source "$(dirname "${BASH_SOURCE[0]}")/media-probe-fixture.sh"
t_source_functions "$repo/linux/scripts/03-media/build/gstreamer/common/setup-gstreamer.sh" prepare_host_cargo_toolchain_env _gst_prepare_target_cargo_env
t_source_functions "$repo/linux/scripts/03-media/build/gstreamer/common/build-gst-plugins-rs.sh" _gst_rs_host_cargo_config
host_setup="$(declare -f prepare_host_cargo_toolchain_env)"
resolve_host_gcc_for_cargo() { printf '/host compiler/cc'; }
resolve_host_gxx_for_cargo() { printf '/host compiler/cxx'; }
prepare_cargo_host_linker_wrapper() { printf '%s' "${wrapper_cc}"; }
prepare_cargo_host_cxx_wrapper() { printf '%s' "${wrapper_cxx}"; }
cross_build_upper_rust() { printf '%s' "$build_upper"; }
cross_build_lower_rust() { printf '%s' "$build_lower"; }
_gst_prepare_target_cargo_env_saved="$(declare -f _gst_prepare_target_cargo_env)"
_gst_prepare_target_cargo_env() { :; }
for caller in monorepo standalone; do
  for mode in cross native empty-tags empty-wrapper; do
    t_case "$caller $mode preserves Rust host defaults and host-variable publication policy"
    unset CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER CC_x86_64_unknown_linux_gnu CXX_x86_64_unknown_linux_gnu HOST_CC HOST_CXX CARGO_TARGET_CUSTOM_LINKER CC_custom CXX_custom
    wrapper_cc='/wrapped host/cc'; wrapper_cxx='/wrapped host/cxx'
    build_upper=CUSTOM; build_lower=custom
    [ "$mode" != empty-tags ] || { build_upper=''; build_lower=''; }
    [ "$mode" != empty-wrapper ] || { wrapper_cc=''; wrapper_cxx=''; }
    if [ "$caller" = standalone ]; then unset -f prepare_host_cargo_toolchain_env; _gst_rs_host_cargo_config; else eval "$host_setup"; prepare_host_cargo_toolchain_env; fi
    expected_cc="$wrapper_cc"; expected_cxx="$wrapper_cxx"
    [ "$mode" != native ] || { expected_cc='unset'; expected_cxx='unset'; }
    upper=CUSTOM; lower=custom
    if [ "$caller" = standalone ] || [ "$mode" = empty-tags ]; then upper=X86_64_UNKNOWN_LINUX_GNU; lower=x86_64_unknown_linux_gnu; fi
    var="CARGO_TARGET_${upper}_LINKER"; t_assert_eq "$expected_cc" "${!var-unset}"
    var="CC_${lower}"; t_assert_eq "$expected_cc" "${!var-unset}"
    var="CXX_${lower}"; t_assert_eq "$expected_cxx" "${!var-unset}"
    host_cc='unset'; host_cxx='unset'
    if [ "$caller" = monorepo ] && [ "$mode" != native ]; then host_cc="$wrapper_cc"; host_cxx="$wrapper_cxx"; fi
    t_assert_eq "$host_cc|$host_cxx" "${HOST_CC-unset}|${HOST_CXX-unset}"
    linker_var="CARGO_TARGET_${upper}_LINKER"; c_var="CC_${lower}"; cxx_var="CXX_${lower}"
    media_probe_record host "$caller" "$mode" "$upper" "$lower" "${HOST_CC-unset}|${HOST_CXX-unset}" "${!linker_var-unset}" "${!c_var-unset}" "${!cxx_var-unset}"
  done
done
eval "$_gst_prepare_target_cargo_env_saved"
cross_target_upper_rust() { printf TARGET; }
cross_target_lower_rust() { printf target; }
cross_target_arch() { printf fixture; }
resolve_cross_cc_cxx_for_arch() {
  printf 'resolve:%s\n' "$*" >> "$work/trace"
  export CC='/resolved cc' CXX='/resolved cxx'
  return "$resolve_rc"
}
export_cargo_target_linker() { printf '<%s>\n' "$@" >> "$work/trace"; return 0; }
for resolve_rc in 0 7; do
  t_case "target compiler lookup preserves isolated environment and resolver status $resolve_rc"
  : > "$work/trace"; CC=original-cc; CXX=original-cxx
  rc=0
  _gst_prepare_target_cargo_env > "$work/out" 2>&1 || rc=$?
  expected=$'resolve:fixture\nresolve:fixture\n<TARGET>\n<target>\n</resolved cc>\n</resolved cxx>'
  [ "$resolve_rc" = 0 ] || expected=$'resolve:fixture\nresolve:fixture\n<TARGET>\n<target>\n<>\n<>'
  t_assert_eq "$expected" "$(cat "$work/trace")"
  t_assert_eq original-cc/original-cxx "$CC/$CXX"
  t_assert_eq 0 "$rc"
  media_probe_record target "$resolve_rc" "$rc" "$CC/$CXX" "$(cat "$work/trace")" "$(cat "$work/out")"
done
for name_mode in ready empty absent partial; do
  t_case "target Rust names $name_mode retain ordered probes and best-effort stdout"
  cross_target_upper_rust() { media_probe_answer upper TARGET "$name_mode" "$work/names"; }
  cross_target_lower_rust() { media_probe_answer lower target "$name_mode" "$work/names"; }
  if [ "$name_mode" = absent ]; then media_probe_hide_commands cross_target_upper_rust cross_target_lower_rust; fi
  : > "$work/names"; : > "$work/trace"; resolve_rc=0
  _gst_prepare_target_cargo_env > "$work/out" 2>&1
  expected=$'upper\nlower'; [ "$name_mode" != absent ] || expected=''
  t_assert_eq "$expected" "$(cat "$work/names")"
  expected=$'resolve:fixture\nresolve:fixture\n<TARGET>\n<target>\n</resolved cc>\n</resolved cxx>'
  case "$name_mode" in empty|absent) expected='' ;; esac
  t_assert_eq "$expected" "$(cat "$work/trace")"
  media_probe_record names "$name_mode" "$(cat "$work/names")" "$(cat "$work/trace")" "$(cat "$work/out")"
  media_probe_restore_commands
done
t_case 'validated target bindings preserve executable checks and optional CXX/lower fields'
t_source_functions "$repo/linux/scripts/01-core/cross-env.sh" export_cargo_target_linker
printf '#!/bin/sh\nexit 0\n' > "$work/cc"
cp "$work/cc" "$work/cxx"; chmod +x "$work/cc" "$work/cxx"
unset CARGO_TARGET_CHECK_LINKER CC_check CXX_check
HOST_CC=keep-host-cc; HOST_CXX=keep-host-cxx
t_assert_eq 1 "$(t_rc export_cargo_target_linker CHECK check "$work/missing" "$work/cxx")"
t_assert_eq unset "${CARGO_TARGET_CHECK_LINKER-unset}"
export_cargo_target_linker CHECK check "$work/cc" "$work/missing"
t_assert_eq "$work/cc|$work/cc|unset" "$CARGO_TARGET_CHECK_LINKER|${CC_check-unset}|${CXX_check-unset}"
export_cargo_target_linker CHECK check "$work/cc" "$work/cxx"
t_assert_eq "$work/cxx" "$CXX_check"
t_assert_eq keep-host-cc/keep-host-cxx "$HOST_CC/$HOST_CXX"
unset CC_check CXX_check
export_cargo_target_linker CHECK '' "$work/cc" "$work/cxx"
t_assert_eq unset/unset "${CC_check-unset}/${CXX_check-unset}"
media_probe_record validated "$CARGO_TARGET_CHECK_LINKER" "${CC_check-unset}" "${CXX_check-unset}" "$HOST_CC" "$HOST_CXX"
t_summary
