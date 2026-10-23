#!/usr/bin/env bash
# Source wiring checks complement runtime receipts; they do not execute builds or publication.
runtime_test_preparation_step() {
  local scripts="$1" anchor="$2" expected="$3" entry
  for entry in build-runtime-manifest.sh build-runtime-artifacts.sh; do
    t_assert_ok grep -q '^  runtime_prepare_flow ' "${scripts}/${entry}"
    t_assert_eq "${expected}" "$(grep -F -A1 "${anchor}" "${scripts}/01-core/runtime-flow-common.sh" | sed -n 2p)" "${entry} preparation order"
  done
}
