#!/usr/bin/env bash
# parallelism.sh - build parallelism helpers (CPU quota + optional memory cap)
[ -n "${_PARALLELISM_SH_LOADED:-}" ] && return 0
_PARALLELISM_SH_LOADED=1
#
# Environment Variables:
#   AGGRESSIVE_PARALLELISM  - Set to "true" for lower memory caps (faster builds)
#                              Auto-enabled when host RAM >= 16GB.
#   PARALLEL_JOBS           - Override all auto-detection with explicit job count
#   DEFAULT_MB_PER_JOB      - Override default memory per job (default: 2000 or 800 if aggressive)

_cgroup_cpu_quota_cores() {
  local quota=""
  local period=""

  # cgroup v2
  if [ -r /sys/fs/cgroup/cpu.max ]; then
    # format: "max <period>" or "<quota> <period>"
    read -r quota period < /sys/fs/cgroup/cpu.max || true
    if [ -n "${quota}" ] && [ "${quota}" != "max" ] && [ -n "${period}" ] && [ "${period}" -gt 0 ] 2>/dev/null; then
      printf '%s\n' $(( (quota + period - 1) / period ))
      return 0
    fi
  fi

  # cgroup v1
  if [ -r /sys/fs/cgroup/cpu/cpu.cfs_quota_us ] && [ -r /sys/fs/cgroup/cpu/cpu.cfs_period_us ]; then
    quota="$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us 2>/dev/null || printf '')"
    period="$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us 2>/dev/null || printf '')"
    if [ -n "${quota}" ] && [ -n "${period}" ] && [ "${quota}" -gt 0 ] 2>/dev/null && [ "${period}" -gt 0 ] 2>/dev/null; then
      printf '%s\n' $(( (quota + period - 1) / period ))
      return 0
    fi
  fi

  printf '%s\n' ""
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
  printf '%s\n' "${cores}"
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
  printf '%s\n' "${jobs}"
}

_mem_available_mb() {
  local avail_mb
  avail_mb="$(awk '/MemAvailable/ {printf("%d",$2/1024); exit}' /proc/meminfo 2>/dev/null || true)"

  local cgroup_mb
  cgroup_mb="$(_cgroup_mem_remaining_mb)"
  if [ -n "${cgroup_mb}" ]; then
    if [ -z "${avail_mb}" ] || [ "${cgroup_mb}" -lt "${avail_mb}" ] 2>/dev/null; then
      avail_mb="${cgroup_mb}"
    fi
  fi

  if [ -z "${avail_mb}" ]; then
    printf '%s\n' ""
  else
    printf '%s\n' "${avail_mb}"
  fi
}

_cgroup_mem_remaining_mb() {
  # Returns approximate remaining memory under cgroup limits (in MB), if set.
  # Works for cgroup v2 and v1. Returns empty if unlimited/unknown.
  local max="" current="" remaining_bytes=""

  # cgroup v2
  if [ -r /sys/fs/cgroup/memory.max ]; then
    max="$(cat /sys/fs/cgroup/memory.max 2>/dev/null || printf '')"
    if [ -n "${max}" ] && [ "${max}" != "max" ] 2>/dev/null; then
      if [ -r /sys/fs/cgroup/memory.current ]; then
        current="$(cat /sys/fs/cgroup/memory.current 2>/dev/null || printf '')"
      fi
      if [ -n "${current}" ] && [ "${current}" -ge 0 ] 2>/dev/null; then
        remaining_bytes=$(( max - current ))
        [ "${remaining_bytes}" -lt 0 ] 2>/dev/null && remaining_bytes=0
        printf '%s\n' $(( remaining_bytes / 1024 / 1024 ))
        return 0
      fi
      printf '%s\n' $(( max / 1024 / 1024 ))
      return 0
    fi
  fi

  # cgroup v1
  if [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
    max="$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null || printf '')"
    # Some kernels report a huge number when effectively unlimited.
    if [ -n "${max}" ] && [ "${max}" -gt 0 ] 2>/dev/null && [ "${max}" -lt 9223372036854771712 ] 2>/dev/null; then
      if [ -r /sys/fs/cgroup/memory/memory.usage_in_bytes ]; then
        current="$(cat /sys/fs/cgroup/memory/memory.usage_in_bytes 2>/dev/null || printf '')"
      fi
      if [ -n "${current}" ] && [ "${current}" -ge 0 ] 2>/dev/null; then
        remaining_bytes=$(( max - current ))
        [ "${remaining_bytes}" -lt 0 ] 2>/dev/null && remaining_bytes=0
        printf '%s\n' $(( remaining_bytes / 1024 / 1024 ))
        return 0
      fi
      printf '%s\n' $(( max / 1024 / 1024 ))
      return 0
    fi
  fi

  printf '%s\n' ""
}

_auto_aggressive_parallelism() {
  # Enable AGGRESSIVE_PARALLELISM automatically when host has plenty of RAM.
  # Explicit AGGRESSIVE_PARALLELISM=false disables this auto-detection.
  if [ "${AGGRESSIVE_PARALLELISM:-}" = "false" ]; then
    return 0
  fi
  if [ "${AGGRESSIVE_PARALLELISM:-}" = "true" ]; then
    return 0
  fi
  local avail_mb
  avail_mb="$(_mem_available_mb)"
  if [ -n "${avail_mb}" ] && [ "${avail_mb}" -ge 16384 ] 2>/dev/null; then
    export AGGRESSIVE_PARALLELISM=true
  fi
}

compute_jobs_with_mem_cap() {
  # Usage: compute_jobs_with_mem_cap [requested] [mb_per_job]
  # Defaults to ~2000MB/job to avoid OOM on build steps.
  # Set AGGRESSIVE_PARALLELISM=false to disable (auto-enabled when RAM >= 16GB).
  # Set PARALLEL_JOBS=N to override all auto-detection.
  local requested="${1:-}"
  local mb_per_job="${2:-}"

  # Allow explicit override via PARALLEL_JOBS
  if [ -n "${PARALLEL_JOBS:-}" ]; then
    printf '%s\n' "${PARALLEL_JOBS}"
    return 0
  fi

  # Auto-enable aggressive mode on high-memory hosts if not explicitly set
  _auto_aggressive_parallelism

  # Determine default memory per job based on AGGRESSIVE_PARALLELISM
  if [ -z "${mb_per_job}" ]; then
    if [ "${AGGRESSIVE_PARALLELISM:-false}" = "true" ]; then
      mb_per_job="${DEFAULT_MB_PER_JOB:-800}"
    else
      mb_per_job="${DEFAULT_MB_PER_JOB:-2000}"
    fi
  fi

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
  printf '%s\n' "${jobs}"
}

# Compute jobs for Rust/Cargo builds (typically need more memory)
# Usage: compute_rust_jobs [requested]
compute_rust_jobs() {
  local requested="${1:-}"
  local mb_per_job

  if [ "${AGGRESSIVE_PARALLELISM:-false}" = "true" ]; then
    mb_per_job="${RUST_MB_PER_JOB:-1200}"
  else
    mb_per_job="${RUST_MB_PER_JOB:-2500}"
  fi

  compute_jobs_with_mem_cap "${requested}" "${mb_per_job}"
}

# Compute jobs for memory-HEAVY C++ builds (PyTorch/torch_cpu, large LLVM/TU
# link steps, etc.) whose individual cc1plus translation units peak far above
# the ~2GB/job the generic default assumes. torch's aten/autograd TUs peak
# ~4GB/cc1plus; running them at the media default (2GB/job) overcommits RAM and
# the OOM-killer terminates cc1plus (observed on the riscv64 litert build,
# 27 jobs x 4GB on a 60GB host, tipped over by concurrent external load).
# Use this for any build that compiles PyTorch or comparably heavy C++.
# Usage: compute_cpp_heavy_jobs [requested]
compute_cpp_heavy_jobs() {
  local requested="${1:-}"
  # Aggressive mode still respects a real 4GB floor here -- these TUs do not get
  # cheaper on a big host; more RAM just means more of them can run at once,
  # which the avail_mb/mb_per_job cap already accounts for.
  compute_jobs_with_mem_cap "${requested}" "${CPP_HEAVY_MB_PER_JOB:-4096}"
}
