#!/usr/bin/env bash
# parallelism.sh - build parallelism helpers (CPU quota + optional memory cap)

_cgroup_cpu_quota_cores() {
  local quota=""
  local period=""

  # cgroup v2
  if [ -r /sys/fs/cgroup/cpu.max ]; then
    # format: "max <period>" or "<quota> <period>"
    read -r quota period < /sys/fs/cgroup/cpu.max || true
    if [ -n "${quota}" ] && [ "${quota}" != "max" ] && [ -n "${period}" ] && [ "${period}" -gt 0 ] 2>/dev/null; then
      echo $(( (quota + period - 1) / period ))
      return 0
    fi
  fi

  # cgroup v1
  if [ -r /sys/fs/cgroup/cpu/cpu.cfs_quota_us ] && [ -r /sys/fs/cgroup/cpu/cpu.cfs_period_us ]; then
    quota="$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us 2>/dev/null || echo "")"
    period="$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us 2>/dev/null || echo "")"
    if [ -n "${quota}" ] && [ -n "${period}" ] && [ "${quota}" -gt 0 ] 2>/dev/null && [ "${period}" -gt 0 ] 2>/dev/null; then
      echo $(( (quota + period - 1) / period ))
      return 0
    fi
  fi

  echo ""
}

detect_available_cores() {
  local cores
  cores="$(nproc --all 2>/dev/null || nproc 2>/dev/null || echo 1)"
  [ "${cores}" -lt 1 ] 2>/dev/null && cores=1

  local quota_cores
  quota_cores="$(_cgroup_cpu_quota_cores)"
  if [ -n "${quota_cores}" ] && [ "${quota_cores}" -gt 0 ] 2>/dev/null; then
    if [ "${quota_cores}" -lt "${cores}" ] 2>/dev/null; then
      cores="${quota_cores}"
    fi
  fi

  [ "${cores}" -lt 1 ] 2>/dev/null && cores=1
  echo "${cores}"
}

compute_jobs() {
  # Usage: compute_jobs [requested]
  local requested="${1:-}"
  local cores
  cores="$(detect_available_cores)"

  local jobs="${cores}"
  if [ -n "${requested}" ]; then
    jobs="${requested}"
  fi

  # Cap to detected available cores
  if [ "${jobs}" -gt "${cores}" ] 2>/dev/null; then
    jobs="${cores}"
  fi

  [ "${jobs}" -lt 1 ] 2>/dev/null && jobs=1
  echo "${jobs}"
}

_mem_available_mb() {
  local avail_mb
  avail_mb="$(awk '/MemAvailable/ {printf("%d",$2/1024); exit}' /proc/meminfo 2>/dev/null || true)"
  if [ -z "${avail_mb}" ]; then
    echo ""
  else
    echo "${avail_mb}"
  fi
}

compute_jobs_with_mem_cap() {
  # Usage: compute_jobs_with_mem_cap [requested] [mb_per_job]
  # Defaults to ~2000MB/job to avoid OOM on build steps.
  local requested="${1:-}"
  local mb_per_job="${2:-2000}"

  local jobs
  jobs="$(compute_jobs "${requested}")"

  local avail_mb max_by_mem
  avail_mb="$(_mem_available_mb)"
  if [ -n "${avail_mb}" ] && [ "${mb_per_job}" -gt 0 ] 2>/dev/null; then
    max_by_mem=$(( avail_mb / mb_per_job ))
    [ "${max_by_mem}" -lt 1 ] && max_by_mem=1
    if [ "${jobs}" -gt "${max_by_mem}" ] 2>/dev/null; then
      jobs="${max_by_mem}"
    fi
  fi

  [ "${jobs}" -lt 1 ] && jobs=1
  echo "${jobs}"
}
