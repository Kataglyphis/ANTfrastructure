#!/usr/bin/env bash
# Offline setup receipts cover markers, import context and apt cleanup, not real Python modules, apt transactions or image acceptance.
set -euo pipefail
# shellcheck source=linux/scripts/tests/torch-setup-fixture.sh
source "$(dirname "${BASH_SOURCE[0]}")/torch-setup-fixture.sh"
for action in fallback verify deps riscv; do
  case "$action" in
    fallback) scenarios='plain wheel source copy-failure pip-failure mkdir-failure write-failure marker-directory' ;;
    verify) scenarios='ready fatal allow mkdir-failure write-failure marker-directory' ;;
    deps) scenarios='plain mounted mount-error rm-failure update-failure closure-failure cross' ;;
    riscv) scenarios='plain mounted rm-failure update-failure install-failure' ;;
  esac
  for scenario in $scenarios; do
    t_case "$action $scenario preserves status, marker and filesystem policy"
    torch_setup_run "$action" "$scenario"
    expected_status=0
    case "$action:$scenario" in
      verify:fatal) expected_status=1 ;;
      fallback:pip-failure) expected_status=9 ;;
      *:rm-failure) expected_status=11 ;;
      *:update-failure) expected_status=17 ;;
      deps:closure-failure) expected_status=23 ;;
    esac
    t_assert_eq "$expected_status" "$TORCH_STATUS"
    marker=missing; marker_bytes=''
    if [ -d "$TORCH_CASE/venv/.torch-missing" ]; then marker=directory
    elif [ -f "$TORCH_CASE/venv/.torch-missing" ]; then marker='file'; marker_bytes="$(torch_setup_bytes "$TORCH_CASE/venv/.torch-missing")"; fi
    if [ "$action" = fallback ] && [ "$scenario" != pip-failure ] || [ "$action" = verify ] && [ "$scenario" != fatal ]; then
      expected_marker='file'; [ "$scenario" != marker-directory ] || expected_marker=directory
      t_assert_eq "$expected_marker" "$marker"
      if [ "$scenario" = ready ]; then expected=previous
      elif [ "$scenario" = write-failure ] || [ "$scenario" = marker-directory ]; then expected=''
      elif [ "$action" = fallback ]; then expected='fixture-arch: no torch wheel in /opt/wheels at build time; assemble-torch-app.sh skipped'
      else expected='fixture-arch: torch not importable after assemble-torch-app; ALLOW_TORCHLESS_RUNTIME=1'; fi
      if [ "$marker" = file ]; then t_assert_eq "$expected" "$(cat "$TORCH_CASE/venv/.torch-missing")"; fi
    else
      t_assert_eq missing "$marker"
    fi
    imports="$(grep -c '^python|' "$TORCH_CASE/trace" || true)"
    case "$action:$scenario" in
      fallback:pip-failure|deps:*|riscv:*) t_assert_eq 0 "$imports" ;;
      fallback:*|verify:ready) t_assert_eq 1 "$imports" ;;
      verify:*) t_assert_eq 2 "$imports" ;;
    esac
    if [ "$action" = verify ]; then t_assert_rc 0 grep -q '^python|cwd=/|' "$TORCH_CASE/trace"; fi
    if [ "$action" = deps ] || [ "$action" = riscv ]; then
      lists="$(/usr/bin/find "$TORCH_CASE/apt/lists" -type f -printf '%f\n' | LC_ALL=C sort)"
      expected_lists=''
      case "$scenario" in mounted|rm-failure|update-failure|closure-failure|cross) expected_lists=$'first list\nsecond' ;; esac
      t_assert_eq "$expected_lists" "$lists"
      if [ "$scenario" = mounted ] || [ "$scenario" = cross ]; then t_assert_rc 1 grep -q '^rm|' "$TORCH_CASE/trace"; fi
      if [ "$scenario" = cross ]; then t_assert_eq initial-libs "$(cat "$TORCH_CASE/ld")"; fi
      if [ "$action:$scenario" = riscv:install-failure ]; then t_assert_contains "$(cat "$TORCH_CASE/out")" 'WARNING: libsleef3 unavailable via apt; import torch will fail (libsleef.so.3 missing)'; fi
    fi
    if [ "$action:$scenario" = fallback:source ]; then t_assert_eq payload "$(cat "$TORCH_CASE/venv/lib/python3.99/site-packages/cv2/payload")"; fi
    if [ "$action:$scenario" = fallback:copy-failure ]; then t_assert_eq false "$([ -e "$TORCH_CASE/venv/lib/python3.99/site-packages/cv2" ] && echo true || echo false)"; fi
    if [ "$scenario" = marker-directory ]; then t_assert_contains "$(cat "$TORCH_CASE/err")" 'Is a directory'; fi
    if [ "$action:$scenario" = verify:fatal ]; then t_assert_contains "$(cat "$TORCH_CASE/err")" 'actual '\''import torch'\'' error'; t_assert_contains "$(cat "$TORCH_CASE/err")" '  import failed'; fi
    t_record_fixture_receipt "$TORCH_SETUP_RECEIPT" "$action" "$scenario" "$TORCH_STATUS" "$marker" "$marker_bytes" "$(torch_setup_bytes "$TORCH_CASE/out")" "$(torch_setup_bytes "$TORCH_CASE/err")" "$(torch_setup_bytes "$TORCH_CASE/trace")" "$(torch_setup_bytes "$TORCH_CASE/ld")"
  done
done
t_summary
