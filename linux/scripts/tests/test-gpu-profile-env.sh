#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
# shellcheck source=/dev/null
source "$repo/linux/scripts/lib/gpu-profile-env.sh"
gpu_without_migraphx_overrides true
export MIGRAPHX_SKIP_BENCHMARKING=1 ORT_MIGRAPHX_MODEL_CACHE_PATH='/tmp/cache with spaces'
export GPU_PROFILE_FIXTURE_KEEP='value with spaces'
# shellcheck disable=SC2016
gpu_without_migraphx_overrides bash -c '
  [[ -z ${MIGRAPHX_SKIP_BENCHMARKING+x} && -z ${ORT_MIGRAPHX_MODEL_CACHE_PATH+x} ]]
  [[ $GPU_PROFILE_FIXTURE_KEEP == "value with spaces" && $1 == "argument with spaces" ]]
' _ 'argument with spaces'
if gpu_without_migraphx_overrides bash -c 'exit 7'; then
  echo 'GPU verification failure was not propagated' >&2
  exit 1
fi
[[ $MIGRAPHX_SKIP_BENCHMARKING == 1 && $ORT_MIGRAPHX_MODEL_CACHE_PATH == '/tmp/cache with spaces' ]]
