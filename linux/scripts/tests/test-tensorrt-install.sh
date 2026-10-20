#!/usr/bin/env bash
# install-tensorrt.sh: the exact package set at the exact build, and a refusal of any other; no apt, no download.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
TRT="${TESTS_DIR}/../01-core/install-tensorrt.sh"
ENVF="${TESTS_DIR}/../01-core/versions.env"
NV="${TESTS_DIR}/../../Dockerfile.nvidia"

_fn() { bash -c 'source "$1"; shift; "$@"' _ "${TRT}" "$@"; }

t_case "the package set: the runtime libraries and the headers ORT builds against, all at one version"
_set="$(_fn trt_packages 11 11.4.0.106-1+cuda13.4)"
t_assert_eq 12 "$(printf '%s\n' "${_set}" | grep -c '=11\.4\.0\.106-1+cuda13\.4$')" "twelve packages, each pinned"
for p in libnvinfer11 libnvinfer-plugin11 libnvonnxparsers11 libnvinfer-lean11 libnvinfer-dispatch11 libnvinfer-vc-plugin11 \
         libnvinfer-dev libnvinfer-headers-dev libnvonnxparsers-dev; do
  t_assert_contains "${_set}" "${p}=" "${p}"
done
t_assert_eq "" "$(printf '%s\n' "${_set}" | grep -E '^(tensorrt|tensorrt-libs|tensorrt-dev|libnvinfer-win-builder-resource[0-9]*|python3-libnvinfer[a-z-]*)=' || true)" \
  "no metapackage: they pull the 1.9 GB Windows builder resource"

t_case "an install off the pin is named package by package"
_want="$(_fn trt_packages 11 11.4.0.106-1+cuda13.4)"
_have="$(printf '%s\n' "${_want}" | tr '=' ' ')"
t_assert_eq "" "$(_fn trt_version_mismatches "${_want}" "${_have}")" "every package at the pin"
_have2="$(printf '%s\n' "${_have}" | sed 's/^libnvinfer11 .*/libnvinfer11 11.3.0.99-1+cuda13.4/; /^libnvonnxparsers11 /d')"
_m="$(_fn trt_version_mismatches "${_want}" "${_have2}")"
t_assert_contains "${_m}" "libnvinfer11 wants 11.4.0.106-1+cuda13.4, has 11.3.0.99-1+cuda13.4"
t_assert_contains "${_m}" "libnvonnxparsers11 wants 11.4.0.106-1+cuda13.4, has <none>"
t_assert_eq 2 "$(printf '%s\n' "${_m}" | grep -c .)" "and nothing else"

t_case "the pins exist and reach the gpu stage"
_v="$(sed -n 's/^TENSORRT_VERSION=//p' "${ENVF}")"; _c="$(sed -n 's/^TENSORRT_LINUX_CUDA=//p' "${ENVF}")"
t_assert_ok bash -c '[[ "$1" =~ ^[0-9]+(\.[0-9]+){3}$ ]] && [[ "$2" =~ ^[0-9]+\.[0-9]+$ ]]' _ "${_v}" "${_c}"
t_assert_contains "$(cat "${NV}")" "ARG TENSORRT_LINUX_CUDA=${_c}" "Dockerfile.nvidia declares the CUDA line"
t_assert_contains "$(cat "${NV}")" "bash /tmp/core-scripts/install-tensorrt.sh" "and runs the installer"
t_assert_fails env -u TENSORRT_LINUX_CUDA TENSORRT_VERSION=11.4.0.106 bash -c 'source "$1"; trt_main' _ "${TRT}"

t_summary
