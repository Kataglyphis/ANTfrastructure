#!/usr/bin/env bash
# Command stubs cover cross preparation and the legacy SDK branch; no real library symlink or GStreamer build is changed.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
CORE="${TESTS_DIR}/../03-media/core/common.sh"
STAGE="${1:-${TESTS_DIR}/../03-media/build/gstreamer/common/build-gstreamer-stage.sh}"
eval "$(t_fn_src "$CORE" media_prepare_cross_compilers)"
eval "$(t_fn_src "$CORE" media_pin_target_libstdcxx_if_available)"
_stage_prefix=$(sed -n '/^ensure_gstreamer_multiarch_layout$/,/^cd \/opt$/p' "$STAGE" | sed '$d')
_work=$(mktemp -d)
trap 'rm -rf "$_work"' EXIT
_event() { local IFS='|'; printf '%s\n' "$*" >> "$_work/events"; }

_stage_case() (
    local mode="$1" target="$2" build_mode="$3" cc="$4" cxx="$5" present="$6"
    : > "$_work/events"
    export BUILD_MODE="$build_mode" TARGET_ARCH="$target" TARGETARCH=ignored CC="$cc" CXX="$cxx" GCC_VERSION=fixture
    ensure_gstreamer_multiarch_layout() { _event layout; }
    resolve_cross_cc_cxx_for_arch() { _event resolve "$@"; export CC=target-gcc CXX=target-g++; return 7; }
    fix_libstdcxx_symlink() { _event fix "$@"; return 8; }
    pin_target_libstdcxx() { _event pin "$@"; return 9; }
    arch_deb_multiarch_triplet_for() { _event arch "$@"; printf fixture-triplet; }
    ln() { _event link "$@"; }
    # Legacy SDK existence checks use fixture answers rather than host libraries.
    function [ {
        case "${1:-}:${2:-}" in
            -L:/usr/lib/*/libstdc++.so|-f:/opt/gcc-*/libstdc++.so) return "$present" ;;
            *) builtin [ "$@" ;;
        esac
    }
    case "$mode" in
        modern) : ;;
        old) unset -f fix_libstdcxx_symlink pin_target_libstdcxx ;;
        old-no-map) unset -f fix_libstdcxx_symlink pin_target_libstdcxx arch_deb_multiarch_triplet_for ;;
        no-resolver) unset -f resolve_cross_cc_cxx_for_arch ;;
    esac
    eval "$_stage_prefix"
    printf '%s|%s' "$CC" "$CXX" > "$_work/compilers"
)

_stage_probe() {
    _rc=0
    _stage_case "$@" > "$_work/output" 2>&1 || _rc=$?
    _events=$(cat "$_work/events")
    t_assert_eq 0 "$_rc" "$(cat "$_work/output")"
    t_assert_eq '' "$(cat "$_work/output")" 'optional preparation stays quiet'
}

t_case 'stage prefix extraction includes the runtime preparation but no build invocation'
t_assert_contains "$_stage_prefix" ensure_gstreamer_multiarch_layout
t_assert_contains "$_stage_prefix" pin_target_libstdcxx
t_assert_eq 0 "$(printf '%s\n' "$_stage_prefix" | grep -c '^bash ' || true)"

for missing in cc cxx both; do
    t_case "cross $missing is repaired before optional runtime fix and pin"
    case "$missing" in cc) cc=''; cxx=existing-cxx ;; cxx) cc=existing-cc; cxx='' ;; both) cc=''; cxx='' ;; esac
    _stage_probe modern arm64 cross "$cc" "$cxx" 0
    t_assert_eq $'layout\nresolve\nfix\npin|arm64' "$_events"
    t_assert_eq 'target-gcc|target-g++' "$(cat "$_work/compilers")" 'resolver exports survive its tolerated failure'
done

t_case 'existing compilers are preserved while foreign runtime preparation still runs'
_stage_probe modern riscv64 cross explicit-c explicit-cxx 0
t_assert_eq $'layout\nfix\npin|riscv64' "$_events"
t_assert_eq 'explicit-c|explicit-cxx' "$(cat "$_work/compilers")"
t_case 'native mode skips all compiler and runtime repair'
_stage_probe modern arm64 native '' '' 0
t_assert_eq layout "$_events"
t_case 'cross amd64 repairs compilers but keeps its existing runtime policy'
_stage_probe modern amd64 cross '' '' 0
t_assert_eq $'layout\nresolve' "$_events"
t_case 'an absent optional resolver does not prevent later runtime preparation'
_stage_probe no-resolver arm64 cross '' '' 0
t_assert_eq $'layout\nfix\npin|arm64' "$_events"

for mapping in old old-no-map; do
    t_case "$mapping keeps the old-SDK fallback in place without host writes"
    _stage_probe "$mapping" arm64 cross '' '' 0
    if [[ "$mapping" == old ]]; then
        triplet=fixture-triplet
        t_assert_contains "$_events" $'resolve\narch|arm64\nlink|-sf|'
    else
        triplet=aarch64-linux-gnu
        t_assert_contains "$_events" $'layout\nresolve\nlink|-sf|'
    fi
    t_assert_contains "$_events" "/opt/gcc-fixture/$triplet/lib64/libstdc++.so|/usr/lib/$triplet/libstdc++.so"
    t_assert_eq 0 "$(grep -c '^pin' "$_work/events" || true)" 'an unavailable pin helper remains optional'
done

t_case 'the old-SDK fallback does not replace a path without the guarded library checks'
_stage_probe old arm64 cross '' '' 1
t_assert_eq $'layout\nresolve\narch|arm64' "$_events"

t_case 'the shared compiler preparation is idempotent once both exports are populated'
(
    export BUILD_MODE=cross CC='' CXX=''
    : > "$_work/events"
    resolve_cross_cc_cxx_for_arch() { _event resolve; export CC=target-gcc CXX=target-g++; }
    media_prepare_cross_compilers
    media_prepare_cross_compilers
)
t_assert_eq resolve "$(cat "$_work/events")"

for available in yes no; do
    t_case "strict stage callers tolerate optional resolver availability=$available"
    _rc=0
    bash -c 'set -eu
eval "$1"
BUILD_MODE=cross CC="" CXX=""
if [ "$2" = yes ]; then resolve_cross_cc_cxx_for_arch() { return 7; }; fi
media_prepare_cross_compilers
printf survived
' _ "$(declare -f media_prepare_cross_compilers)" "$available" > "$_work/strict-output" 2>&1 || _rc=$?
    t_assert_eq 0 "$_rc"
    t_assert_eq survived "$(cat "$_work/strict-output")"
done

t_summary
