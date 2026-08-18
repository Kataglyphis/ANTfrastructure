#!/usr/bin/env bash
[ -n "${_PARALLEL_LOOP_SH_LOADED:-}" ] && return 0
_PARALLEL_LOOP_SH_LOADED=1

# Build a flag-dir *prefix* for run_parallel_arch_loop, honoring $TMPDIR.
# The loop itself mktemp's "<prefix>.XXXXXX" and cleans it up on RETURN, so
# callers must pass a bare prefix here (NOT a pre-created dir).
arch_loop_flag_prefix() {
  printf '%s/%s' "${TMPDIR:-/tmp}" "$1"
}

run_parallel_arch_loop() {
  local fn_name="$1" flagdir_prefix="${2:-/tmp/arch-loop-flags}"
  local max_parallel="${3:-4}"
  shift 3
  local arches=("$@")
  local -a pids=()
  local arch running failed=0
  local _flagdir
  _flagdir="$(mktemp -d "${flagdir_prefix}.XXXXXX")"
  # NO `trap ... RETURN` for cleanup here.
  #
  # A RETURN trap set inside a function is NOT scoped to that function: it stays
  # armed and fires again on the CALLER's return, where ${_flagdir} — a local of
  # this function — no longer exists. Under the orchestrator's `set -u` that
  # aborted build-cross-chain.sh with a bare "_flagdir: unbound variable" the
  # moment _chain_run_build_loop returned, i.e. AFTER every stage had already
  # built successfully, turning a green run into exit 1.
  #
  # Cleanup is therefore explicit at the single exit point below. A fatal err()
  # elsewhere leaks one small flag dir under $TMPDIR; that is strictly better
  # than re-arming a trap that corrupts unrelated function returns.
  # Background workers are SUBSHELLS: variables they set (digest pins,
  # built-this-run flags) are silently lost to the parent. Publish the flag
  # dir so workers can persist small results as files, harvested after the
  # join via an optional caller-defined parallel_loop_harvest() hook.
  export PARALLEL_LOOP_FLAGDIR="${_flagdir}"
  running=0
  for arch in "${arches[@]}"; do
    if _bool_truthy "${PARALLEL_ARCHS:-0}"; then
      {
        # The extra ( ) layer is load-bearing: workers that die via `exit`
        # (err()/die in any sourced helper) would otherwise terminate this
        # background subshell BEFORE `|| touch` runs — the failure flag never
        # appears, the join below discards wait's rc, and a dead lane reads
        # as green. The nested subshell absorbs the exit into a return code.
        ( "${fn_name}" "${arch}" ) || touch "${_flagdir}/failed-${arch}"
      } &
      pids+=($!)
      running=$((running + 1))
      if [ "${running}" -ge "${max_parallel}" ]; then
        wait -n 2>/dev/null || true
        running=$((running - 1))
      fi
    else
      # Sequential path: name the failed arch too (the parallel path warns via
      # the failed-* flag files below). set -e in the caller aborts the chain on
      # the non-zero return, so a failed arch never silently proceeds.
      if ! "${fn_name}" "${arch}"; then
        warn "Arch ${arch} failed during build"
        failed=1
        # O4: PARALLEL_LOOP_FAIL_FAST (default keep-going, for CI resilience) —
        # when truthy, abort the loop on the FIRST arch failure instead of
        # grinding the remaining arches for hours. The failure flag is already
        # set, so the return code is unchanged; only the remaining work is cut.
        # Sequential-path only: the parallel path has already launched every
        # lane, so aborting its join would break the harvest semantics.
        if _bool_truthy "${PARALLEL_LOOP_FAIL_FAST:-0}"; then
          warn "PARALLEL_LOOP_FAIL_FAST=1 — aborting remaining arches after ${arch} failure"
          break
        fi
      fi
    fi
  done
  if _bool_truthy "${PARALLEL_ARCHS:-0}"; then
    local pid
    for pid in "${pids[@]}"; do
      wait "${pid}" 2>/dev/null || true
    done
    local f
    for f in "${_flagdir}"/failed-*; do
      if [ -f "${f}" ]; then
        warn "Arch ${f##*-} failed during parallel build"
        failed=1
      fi
    done
    # Harvest worker-persisted results (e.g. digest pins) back into the
    # parent shell. No-op unless the caller defines the hook.
    if declare -F parallel_loop_harvest >/dev/null 2>&1; then
      parallel_loop_harvest "${_flagdir}"
    fi
  fi
  unset PARALLEL_LOOP_FLAGDIR
  rm -rf "${_flagdir}"
  return "${failed}"
}
