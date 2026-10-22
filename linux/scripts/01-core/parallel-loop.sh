#!/usr/bin/env bash
[ -n "${_PARALLEL_LOOP_SH_LOADED:-}" ] && return 0
_PARALLEL_LOOP_SH_LOADED=1

# A bare prefix, not a dir: the loop mktemp's "<prefix>.XXXXXX" itself and removes it.
arch_loop_flag_prefix() {
  printf '%s/%s' "${TMPDIR:-/tmp}" "$1"
}

# Parallel mode: one background worker per arch, at most <max> at once; returns after every worker has exited.
_parallel_arch_loop() {
  local fn_name="$1" max_parallel="$2" flagdir="$3"
  shift 3
  local arch pid running=0
  local -a pids=()
  for arch in "$@"; do
    {
      # The inner ( ) absorbs a worker's exit; without it || touch never runs and a dead lane reads green.
      ( "${fn_name}" "${arch}" ) || touch "${flagdir}/failed-${arch}"
    } &
    pids+=($!)
    running=$((running + 1))
    if [ "${running}" -ge "${max_parallel}" ]; then
      wait -n 2>/dev/null || true
      running=$((running - 1))
    fi
  done
  for pid in "${pids[@]}"; do
    wait "${pid}" 2>/dev/null || true
  done
}

# Parallel mode, after the waits: name the arches whose workers left a failure flag, then run the caller's harvest.
_parallel_arch_collect() {
  local flagdir="$1" f failed=0
  for f in "${flagdir}"/failed-*; do
    if [ -f "${f}" ]; then
      warn "Arch ${f##*-} failed during parallel build"
      failed=1
    fi
  done
  # Optional caller hook that pulls worker-persisted results back into this shell.
  if declare -F parallel_loop_harvest >/dev/null 2>&1; then
    parallel_loop_harvest "${flagdir}"
  fi
  return "${failed}"
}

# Sequential mode: arches run one after another; a failure is named at once, and fail-fast stops the loop there.
_serial_arch_loop() {
  local fn_name="$1" arch failed=0
  shift
  for arch in "$@"; do
    if ! "${fn_name}" "${arch}"; then
      warn "Arch ${arch} failed during build"
      failed=1
      # Fail-fast is sequential-only: the parallel path has launched every lane and must still harvest.
      if _bool_truthy "${PARALLEL_LOOP_FAIL_FAST:-0}"; then
        warn "PARALLEL_LOOP_FAIL_FAST=1 — aborting remaining arches after ${arch} failure"
        break
      fi
    fi
  done
  return "${failed}"
}

run_parallel_arch_loop() {
  local fn_name="$1" flagdir_prefix="${2:-/tmp/arch-loop-flags}"
  local max_parallel="${3:-4}"
  shift 3
  local _flagdir failed=0
  # Without a writable flag dir worker failures go unrecorded and every arch reads green. docs/failure-modes.md
  if ! _flagdir="$(mktemp -d "${flagdir_prefix}.XXXXXX")" \
     || [ -z "${_flagdir}" ] || [ ! -w "${_flagdir}" ]; then
    warn "run_parallel_arch_loop: no writable flag dir (${flagdir_prefix}.XXXXXX) -- refusing, because arch failures could not be recorded"
    return 1
  fi
  # Subshell workers persist results here. No RETURN trap: it would re-fire on the caller's return, unbound.
  export PARALLEL_LOOP_FLAGDIR="${_flagdir}"
  if _bool_truthy "${PARALLEL_ARCHS:-0}"; then
    _parallel_arch_loop "${fn_name}" "${max_parallel}" "${_flagdir}" "$@"
    _parallel_arch_collect "${_flagdir}" || failed=1
  else
    _serial_arch_loop "${fn_name}" "$@" || failed=1
  fi
  unset PARALLEL_LOOP_FLAGDIR
  rm -rf "${_flagdir}"
  return "${failed}"
}
