#!/usr/bin/env bash
# Real patch fixtures check both pinned source branches and idempotence; no nvcc, cache hits or inference are proved here.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
source "${TESTS_DIR}/git-fixture-env.sh"
COMMON="${TESTS_DIR}/../03-media/build/onnxruntime/build/lib/common.sh"
PATCHES="${TESTS_DIR}/../patches/onnxruntime"
APPLIER="${TESTS_DIR}/../01-core/apply-patch.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
eval "$(t_fn_src "${COMMON}" ort_cuda_standard_options_ok)"
eval "$(t_fn_src "${COMMON}" apply_ort_gpu_source_patches)"

ort_cuda_tree() {
  mkdir -p "$1/cmake" "$1/onnxruntime/contrib_ops/cuda/bert"
  cp "${TESTS_DIR}/fixtures/onnxruntime-cuda-plugin-CMakeLists.txt" "$1/cmake/onnxruntime_providers_cuda_plugin.cmake"
  cat > "$1/onnxruntime/contrib_ops/cuda/bert/dynamic_sparse_attention_impl.h" <<'HEADER'
// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

#pragma once

#include <cuda_runtime.h>

#include "contrib_ops/cpu/bert/dynamic_sparse_attention_parameters.h"
#include "core/common/status.h"
HEADER
}
ort_cuda_apply() {
  (
    err() { printf 'ERR %s\n' "$*" >&2; exit 1; }
    ORT_SRC_DIR="$1" apply_ort_gpu_source_patches "${PATCHES}" "${APPLIER}"
  )
}

t_case 'the actual GPU patch policy joins both pinned CUDA C++20 branches and leaves all other source bytes intact'
ort_cuda_tree "${WORK}/valid"
file="${WORK}/valid/cmake/onnxruntime_providers_cuda_plugin.cmake"
python3 - "${file}" "${WORK}/expected.txt" <<'PYTHON'
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_bytes()
Path(sys.argv[2]).write_bytes(text.replace(b"SHELL:--std c++20", b"SHELL:-std=c++20"))
PYTHON
out="$(ort_cuda_apply "${WORK}/valid" 2>&1)"; rc=$?
t_assert_eq 0 "${rc}" "${out}"
t_assert_eq 2 "$(grep -cF 'SHELL:-std=c++20>' "${file}" || true)" 'both main and object-library branches are normalized'
t_assert_eq 0 "$(grep -cF 'SHELL:--std' "${file}" || true)" 'no separated standard reaches the cache parser'
t_assert_eq 0 "$(t_rc cmp "${WORK}/expected.txt" "${file}")" 'warnings, architecture choices and all other bytes survive'

t_case 'the canonical patch policy is byte-stable on a repeated build'
before="$(sha256sum "${file}")"
t_assert_eq 0 "$(t_rc ort_cuda_apply "${WORK}/valid")"
t_assert_eq "${before}" "$(sha256sum "${file}")"

t_case 'the same canonical policy applies and repeats through the Git backend'
ort_cuda_tree "${WORK}/git"
git -C "${WORK}/git" init -q || exit 1
git -C "${WORK}/git" config core.autocrlf false || exit 1
t_git_commit "${WORK}/git" || exit 1
out="$(ort_cuda_apply "${WORK}/git" 2>&1)"; rc=$?
t_assert_eq 0 "${rc}" "${out}"
t_assert_eq 0 "$(t_rc cmp "${WORK}/expected.txt" "${WORK}/git/cmake/onnxruntime_providers_cuda_plugin.cmake")"
t_assert_eq 0 "$(t_rc ort_cuda_apply "${WORK}/git")"
t_assert_eq 0 "$(t_rc cmp "${WORK}/expected.txt" "${WORK}/git/cmake/onnxruntime_providers_cuda_plugin.cmake")"

t_case 'the postcondition rejects missing, partial, excessive or remaining separated standard options'
t_assert_eq 1 "$(t_rc ort_cuda_standard_options_ok "${WORK}/missing")"
for bad in '' 'SHELL:-std=c++20>' \
    $'SHELL:-std=c++20>\nSHELL:-std=c++20>\nSHELL:-std=c++20>' \
    $'SHELL:-std=c++20>\nSHELL:-std=c++20>\nSHELL:--std\tc++20>' \
    $'SHELL:-std=c++20>\nSHELL:-std=c++20>\nSHELL:--std=c++17>' \
    $'SHELL:-std=c++200>\nSHELL:-std=c++200>'; do
  printf '%s' "${bad}" > "${WORK}/bad.cmake"
  t_assert_eq 1 "$(t_rc ort_cuda_standard_options_ok "${WORK}/bad.cmake")" 'drifted source must fail'
done

t_case 'the actual patch pipeline refuses an unexpected third source option before configuration'
ort_cuda_tree "${WORK}/drift"
printf '\n"$<$<COMPILE_LANGUAGE:CUDA>:SHELL:--std c++20>"\n' >> "${WORK}/drift/cmake/onnxruntime_providers_cuda_plugin.cmake"
out="$(ort_cuda_apply "${WORK}/drift" 2>&1)"; rc=$?
t_assert_eq 1 "${rc}"
t_assert_contains "${out}" 'ORT CUDA plugin standard options are not verified'

t_summary
