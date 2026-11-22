#!/usr/bin/env bash
# Protocol doubles exercise argv, failures and sequencing, not real native or GPU execution.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
t_private_tmpdir
work="$(t_mktemp -d)"
driver="${TESTS_DIR}/../replay-native-tensor-pair.sh"
export PAIR_FIXTURE="${TESTS_DIR}/native_tensor_pair_fixture.py"
REAL_PYTHON="$(command -v python3)"
export REAL_PYTHON
cat > "${work}/python with spaces" <<'SH'
#!/usr/bin/env bash
exec "${REAL_PYTHON}" "${PAIR_FIXTURE}" python "$@"
SH
chmod +x "${work}/python with spaces"
for mode in good native-cpu native-migraphx no-profile extra-profile profile summary; do
  t_case "${mode}: preserve raw transport and verifier outcomes"
  expected=0
  case "${mode}" in native-cpu) expected=41 ;; native-migraphx) expected=43 ;; no-profile|extra-profile) expected=1 ;; profile) expected=37 ;; summary) expected=39 ;; esac
  report='' raw=125
  t_capture_command report raw env PAIR_MODE="${mode}" MIGRAPHX_SENTINEL=deny ORT_MIGRAPHX_SENTINEL=deny \
    bash "${driver}" "${work}/python with spaces" "${work}/${mode}" 'model with spaces.onnx' 1,3,640,640 'input with spaces.f32le' -- \
    "${REAL_PYTHON}" "${PAIR_FIXTURE}" runner 'prefix argument with spaces'
  t_assert_eq "${expected}" "${raw}" "${mode} must retain its raw result"
  if [[ "${mode}" == no-profile || "${mode}" == extra-profile ]]; then
    t_assert_contains "${report}" "Expected exactly one completed profile"
  fi
  if [[ "${mode}" == good ]]; then
    t_assert_eq '{"acceptance": false}' "$(cat "${work}/good/tensor-summary.json")"
    t_assert_contains "$(cat "${work}/good/cpu/runner.json")" 'model with spaces.onnx'
    t_assert_contains "$(cat "${work}/good/migraphx/runner.json")" 'input with spaces.f32le'
  else
    t_assert_rc 1 test -e "${work}/${mode}/tensor-summary.json"
  fi
done
t_case 'an existing empty output directory refuses before child work'
mkdir "${work}/existing"
t_assert_rc 1 env PAIR_MODE=good bash "${driver}" "${work}/python with spaces" "${work}/existing" model 1,3,640,640 input -- \
  "${REAL_PYTHON}" "${PAIR_FIXTURE}" runner 'prefix argument with spaces'
t_assert_rc 1 test -e "${work}/existing/cpu"
t_case 'a missing separator and insufficient argv fail before allocating evidence'
t_assert_rc 2 bash "${driver}" python "${work}/invalid" model 1 input wrong command
t_assert_rc 2 bash "${driver}" python "${work}/missing" model 1 input --
t_assert_rc 1 test -e "${work}/invalid"
t_summary
