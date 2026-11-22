#!/usr/bin/env bash
# Host diagnostics preserve raw failures and every-run profiles; successful transport is not numerical acceptance.
set -euo pipefail
shopt -s nullglob
scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${scripts}/lib/cli-value-options.sh"
source "${scripts}/lib/gpu-profile-env.sh"
cli_require_positionals 'PYTHON NEW_OUTPUT MODEL SHAPE INPUT -- COMMAND_PREFIX...' 7 0 "$@"
python="$1" output="$2" model="$3" shape="$4" input="$5"
[[ "$6" == -- ]] || { printf 'Expected -- before the command prefix\n' >&2; exit 2; }
shift 6
runner=("$@")
hub="$(cd "${scripts}/../.." && pwd)"
mkdir "${output}"
for selected in cpu migraphx; do
  gpu_without_migraphx_overrides "${runner[@]}" "${model}" "${shape}" "${input}" "${selected}" "${output}/${selected}" > "${output}/${selected}.log" 2>&1
  profiles=("${output}/${selected}"/profile*.json)
  [[ "${#profiles[@]}" == 1 ]] || { printf 'Expected exactly one completed profile for %s\n' "${selected}" >&2; exit 1; }
  device=cpu
  if [[ "${selected}" == migraphx ]]; then device=migraphx-plugin; fi
  "${python}" -I "${hub}/shared/python/verify_ort_profile.py" "${profiles[0]}" --device "${device}" --min-runs 2 > "${output}/${selected}-verdict.txt" 2>&1
done
"${python}" -I "${hub}/shared/python/summarize_detector_tensors.py" "${output}/cpu/tensors" "${output}/migraphx/tensors" --runs 2 --output "${output}/tensor-summary.json" > "${output}/summary.log" 2>&1
