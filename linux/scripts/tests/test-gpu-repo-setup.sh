#!/usr/bin/env bash
# Offline driver receipts cover repository bytes and exact fetch/install policy, not apt signatures, package availability or live networking.
set -euo pipefail
# shellcheck source=linux/scripts/tests/gpu-repo-fixture.sh
source "$(dirname "${BASH_SOURCE[0]}")/gpu-repo-fixture.sh"
for component in cuda rocm; do
  for pins in env file none; do
    for fetch_rc in 0 7; do
      for context in direct conditional; do
      t_case "$component $pins $context fetch status $fetch_rc preserves complete streams and command policy"
      gpu_repo_run "$component" "$pins" amd64 arm64 "$fetch_rc" false 10.0 "$context"
      t_assert_eq "$fetch_rc" "$GPU_STATUS"
      expected_out=$'mirror stdout\nfetch stdout'
      expected_err=$'mirror stderr'
      if [ "$pins" = none ]; then
        if [ "$component" = cuda ]; then warning='WARNING: no CUDA keyring sha pin for x86_64 — fetching the apt trust anchor UNVERIFIED'
        else warning='WARNING: ROCM_GPG_KEY_SHA256 unset — fetching the ROCm apt key UNVERIFIED'; fi
        expected_err+=$'\n'"$warning"
      fi
      expected_err+=$'\nfetch stderr'
      if [ "$fetch_rc" = 0 ] && [ "$context" = direct ]; then
        if [ "$component" = cuda ]; then
          expected_out+=$'\ninstall stdout\nCUDA cross repo enabled for TARGET_ARCH=arm64: ubuntu2604/cross-linux-sbsa'
          expected_err+=$'\ninstall stderr'
        else
          expected_out+=$'\nrocm: every installed amdrocm package belongs to ROCm 10.0'
          expected_err+=$'\ngpg stderr'
        fi
      fi
      t_assert_eq "$expected_out" "$(cat "$GPU_CASE/stdout")"
      t_assert_eq "$expected_err" "$(cat "$GPU_CASE/stderr")"
      if [ "$pins" = none ]; then
        t_assert_rc 0 grep -q '^unverified ' "$GPU_CASE/trace"
        t_assert_contains "$(cat "$GPU_CASE/trace")" '<3>'
      else
        sha="$pins-x86"; [ "$component" != rocm ] || sha="$pins-rocm"
        t_assert_rc 0 grep -q '^verified ' "$GPU_CASE/trace"
        t_assert_contains "$(cat "$GPU_CASE/trace")" "<$sha>"
      fi
      if [ "$fetch_rc" != 0 ] || [ "$context" = conditional ]; then
        t_assert_rc 1 grep -q -E '^(gpg|dpkg) ' "$GPU_CASE/trace"
      elif [ "$component" = rocm ]; then
        sed "s|$GPU_CASE||g" "$GPU_CASE/rocm.sources" > "$GPU_CASE/normalized.sources"
        t_assert_rc 0 cmp "${_T_SCRIPTS}/tests/fixtures/gpu-repos/rocm.sources" "$GPU_CASE/normalized.sources"
        t_assert_eq 2 "$(grep -c '^Types: deb$' "$GPU_CASE/rocm.sources")"
        t_assert_eq 2 "$(grep -c '^Architectures: amd64$' "$GPU_CASE/rocm.sources")"
        t_assert_eq 2 "$(sed "s|$GPU_CASE||g" "$GPU_CASE/rocm.sources" | grep -c '^Signed-By: /etc/apt/keyrings/rocm.gpg$')"
      else
        t_assert_eq 'deb [signed-by=/usr/share/keyrings/cuda-archive-keyring.gpg] https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2604/cross-linux-sbsa/ /' "$(cat "$GPU_CASE/etc/apt/sources.list.d/cuda-cross.list")"
      fi
      gpu_repo_record "$component" "$pins" "$context" "$fetch_rc" "$GPU_STATUS" "$(gpu_repo_bytes "$GPU_CASE/stdout")" "$(gpu_repo_bytes "$GPU_CASE/stderr")" "$(gpu_repo_bytes "$GPU_CASE/trace")" "$(gpu_repo_bytes "$GPU_CASE/rocm.sources")"
      done
    done
  done
done
t_case 'native arm64 CUDA uses its own pin and carries no foreign cross repository'
gpu_repo_run cuda env arm64 arm64 0 false 10.0
t_assert_eq 0 "$GPU_STATUS"
t_assert_contains "$(cat "$GPU_CASE/trace")" '<env-arm>'
t_assert_contains "$(cat "$GPU_CASE/trace")" '/ubuntu2604/sbsa/cuda-keyring_1.1-1_all.deb'
t_assert_eq false "$([ -f "$GPU_CASE/etc/apt/sources.list.d/cuda-cross.list" ] && echo true || echo false)"
gpu_repo_record arm64 "$GPU_STATUS" "$(gpu_repo_bytes "$GPU_CASE/stdout")" "$(gpu_repo_bytes "$GPU_CASE/stderr")" "$(gpu_repo_bytes "$GPU_CASE/trace")"
t_case 'ROCm ASAN appends exactly one independent signed amd64 stanza'
gpu_repo_run rocm env amd64 amd64 0 true 10.0
t_assert_eq 0 "$GPU_STATUS"
sed "s|$GPU_CASE||g" "$GPU_CASE/rocm.sources" > "$GPU_CASE/normalized.sources"
t_assert_rc 0 cmp "${_T_SCRIPTS}/tests/fixtures/gpu-repos/rocm-asan.sources" "$GPU_CASE/normalized.sources"
t_assert_contains "$(cat "$GPU_CASE/trace")" '<amdrocm-asan10.0>'
gpu_repo_record asan "$GPU_STATUS" "$(gpu_repo_bytes "$GPU_CASE/stdout")" "$(gpu_repo_bytes "$GPU_CASE/stderr")" "$(gpu_repo_bytes "$GPU_CASE/trace")" "$(gpu_repo_bytes "$GPU_CASE/rocm.sources")"
t_case 'ROCm rejects a second release before deleting its repository files'
gpu_repo_run rocm env amd64 amd64 0 false 9.9
t_assert_eq 1 "$GPU_STATUS"
t_assert_contains "$(cat "$GPU_CASE/stderr")" 'ERROR: ROCm 10.0 is pinned, but these installed packages belong to another release:'
t_assert_contains "$(cat "$GPU_CASE/stderr")" amdrocm-core-dev9.9
t_assert_eq true "$([ -f "$GPU_CASE/etc/apt/sources.list.d/rocm.sources" ] && echo true)"
gpu_repo_record foreign "$GPU_STATUS" "$(gpu_repo_bytes "$GPU_CASE/stdout")" "$(gpu_repo_bytes "$GPU_CASE/stderr")" "$(gpu_repo_bytes "$GPU_CASE/trace")"
t_case 'ROCm refuses an arm64 build host before mirror or download activity'
gpu_repo_run rocm env arm64 arm64 0 false 10.0
t_assert_eq 1 "$GPU_STATUS"
t_assert_eq '' "$(cat "$GPU_CASE/stdout")"
t_assert_eq '' "$(cat "$GPU_CASE/trace")"
t_assert_contains "$(cat "$GPU_CASE/stderr")" 'ROCm/MIGraphX lane is amd64-only'
gpu_repo_record unsupported "$GPU_STATUS" "$(gpu_repo_bytes "$GPU_CASE/stdout")" "$(gpu_repo_bytes "$GPU_CASE/stderr")" "$(gpu_repo_bytes "$GPU_CASE/trace")"
t_summary
