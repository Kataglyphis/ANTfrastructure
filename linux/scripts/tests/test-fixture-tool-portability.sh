#!/usr/bin/env bash
# Restricted PATH fixtures cover optional-rg independence, not toolchain builds or container execution.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
mkdir -p "${work}/bin"
for tool in bash env awk grep sed head tail cat tr cut wc chmod mkdir rm cp mv dirname basename \
            readlink mktemp touch sleep sort ls file cc gcc as ld readelf timeout find uname date; do
  path="$(command -v "${tool}" 2>/dev/null || true)"
  [ -z "${path}" ] || ln -s "${path}" "${work}/bin/${tool}"
done
python="$(command -v python3)"
ln -s "${python}" "${work}/bin/python3"
t_case "the fixture PATH genuinely has no ripgrep"
t_assert_fails env PATH="${work}/bin" bash -c 'command -v rg'

for spec in 'compiler-target-verdicts 48' 'runtime-probe-transport 43' 'onnx-native-lifecycle 50' \
            'compiler-smoke-command 26' 'media-platform-bootstrap 51' 'ffmpeg-probes 26'; do
  read -r suite count <<< "${spec}"
  t_case "${suite}: every assertion still runs without ripgrep"
  status=0
  output="$(env PATH="${work}/bin" bash "${TESTS_DIR}/test-${suite}.sh" 2>&1)" || status=$?
  t_assert_eq 0 "${status}" "${output}"
  t_assert_contains "${output}" "  ${count} assertion(s) passed"
done
t_summary
