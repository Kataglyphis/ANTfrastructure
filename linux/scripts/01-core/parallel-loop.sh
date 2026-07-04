#!/usr/bin/env bash
[ -n "${_PARALLEL_LOOP_SH_LOADED:-}" ] && return 0
_PARALLEL_LOOP_SH_LOADED=1

run_parallel_arch_loop() {
  local fn_name="$1" flagdir_prefix="${2:-/tmp/arch-loop-flags}"
  local max_parallel="${3:-4}"
  shift 3
  local arches=("$@")
  local -a pids=()
  local arch running failed=0
  local _flagdir
  _flagdir="$(mktemp -d "${flagdir_prefix}.XXXXXX")"
  trap "rm -rf ${_flagdir}" RETURN
  # Background workers are SUBSHELLS: variables they set (digest pins,
  # built-this-run flags) are silently lost to the parent. Publish the flag
  # dir so workers can persist small results as files, harvested after the
  # join via an optional caller-defined parallel_loop_harvest() hook.
  export PARALLEL_LOOP_FLAGDIR="${_flagdir}"
  running=0
  for arch in "${arches[@]}"; do
    if _bool_truthy "${PARALLEL_ARCHS:-0}"; then
      {
        "${fn_name}" "${arch}" || touch "${_flagdir}/failed-${arch}"
      } &
      pids+=($!)
      running=$((running + 1))
      if [ "${running}" -ge "${max_parallel}" ]; then
        wait -n 2>/dev/null || true
        running=$((running - 1))
      fi
    else
      "${fn_name}" "${arch}" || failed=1
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
  return "${failed}"
}
