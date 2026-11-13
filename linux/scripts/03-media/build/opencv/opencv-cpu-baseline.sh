#!/usr/bin/env bash
# Source-only: the amd64 AVX2 baseline request and its configure check; the image gate reads the built module. docs/amd64-x86-64-v3-baseline.md#where-it-is-set

# OpenCV takes its intrinsics width from this variable, not from the compiler default.
opencv_amd64_baseline_args() {
    local -n _oaba_out="$1"
    if [ "$(cross_target_arch)" = "amd64" ]; then _oaba_out+=("-DCPU_BASELINE=AVX2"); fi
    return 0
}

# A configure that fell back from the requested AVX2 baseline would ship 128-bit intrinsics on amd64.
opencv_assert_amd64_baseline() {
    local log="$1" baseline
    [ "$(cross_target_arch)" = "amd64" ] || return 0
    baseline="$(sed -n '/Baseline:/{s/^.*Baseline:[[:space:]]*//p;q}' "${log}")"
    case " ${baseline} " in
        *" AVX2 "*) echo "OpenCV baseline: ${baseline}"; return 0 ;;
    esac
    echo "ERROR: OpenCV configure reports baseline '${baseline}' without AVX2 although CPU_BASELINE=AVX2 was requested; see ${log}" >&2
    return 1
}
