#!/usr/bin/env bash
# Source wiring checks complement runtime receipts; they do not execute builds or publication.
runtime_test_preparation_step() {
  local scripts="$1" anchor="$2" expected="$3" entry
  for entry in build-runtime-manifest.sh build-runtime-artifacts.sh; do
    t_assert_ok grep -q '^  runtime_prepare_flow ' "${scripts}/${entry}"
    t_assert_eq "${expected}" "$(grep -F -A1 "${anchor}" "${scripts}/01-core/runtime-flow-common.sh" | sed -n 2p)" "${entry} preparation order"
  done
}

# Timer workers carry their process companion without executing entrypoint initialization.
runtime_test_timer_sources() {
  local scripts="$1" fn
  shift
  t_fn_src "${scripts}/01-core/parallel-loop.sh" parallel_require_child_stop || return 1
  t_fn_src "${scripts}/01-core/parallel-loop.sh" parallel_stop_child_advisory || return 1
  for fn in "$@"; do
    t_fn_src "${scripts}/01-core/runtime-build-fns.sh" "${fn}" || return 1
    # The timer marks its step for the resource monitor, so it never runs without the marker.
    if [ "${fn}" = _runtime_timed ]; then
      t_fn_src "${scripts}/lib-orchestrator.sh" runtime_step_mark || return 1
      t_fn_src "${scripts}/lib-orchestrator.sh" runtime_step_run || return 1
    fi
  done
}
