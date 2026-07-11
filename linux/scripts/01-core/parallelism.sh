#!/usr/bin/env bash
# parallelism.sh - build parallelism helpers (CPU quota + memory cap)
[ -n "${_PARALLELISM_SH_LOADED:-}" ] && return 0
_PARALLELISM_SH_LOADED=1
#
# ONE model, used by every helper:
#
#     jobs = min( cores , usable_RAM / BUILD_MEM_DIVISOR / peak_MB_per_job )
#
#   cores        detected CPU cores, honoring any cgroup CPU quota.
#   usable_RAM   MemAvailable, or the cgroup memory limit remaining (smaller wins).
#   peak_MB      the PEAK per-translation-unit RSS of the workload (NOT average) --
#                one value per "profile" (generic / rust / heavy), see _profile_mb.
#   DIVISOR      how many builds share this host's RAM concurrently (default 1).
#                Set BUILD_MEM_DIVISOR=N when running N per-arch builds in parallel
#                (--parallel-archs) so N concurrent builds don't N-times overcommit.
#
# BEFORE changing any *_MB_PER_JOB value, read
#   docs/build-parallelism-memory-tuning.md
# The peak numbers are CALIBRATED to host RAM. Lowering them by eyeballing "free"
# RAM OOM-kills multi-hour builds -- the average usage lies because heavy TUs are
# staggered. torch's aten TUs peak ~4GB; that is why heavy stays at 4096.
#
# Environment Variables:
#   PARALLEL_JOBS           - Hard override: exact job count for every helper.
#   AGGRESSIVE_PARALLELISM  - "true" lowers the LIGHT profiles (faster); auto-on
#                             when usable RAM >= 16GB. "false" forces it off.
#   BUILD_MEM_DIVISOR       - Divide usable RAM by this (default 1). Injected by
#                             the orchestrator under --parallel-archs = #arches.
#   DEFAULT_MB_PER_JOB      - Override generic peak (default 2000, or 800 aggressive)
#   RUST_MB_PER_JOB         - Override rust peak    (default 2500, or 1200 aggressive)
#   CPP_HEAVY_MB_PER_JOB    - Override torch/heavy peak (default 4096; see doc)

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
  case "${AGGRESSIVE_PARALLELISM:-}" in true|false) return 0 ;; esac
  local avail_mb
  avail_mb="$(_mem_available_mb)"
  if [ -n "${avail_mb}" ] && [ "${avail_mb}" -ge 16384 ] 2>/dev/null; then
    export AGGRESSIVE_PARALLELISM=true
  fi
}

_usable_mem_mb() {
  # usable RAM this build may assume, after dividing the host pool by the number
  # of builds sharing it concurrently (BUILD_MEM_DIVISOR, default 1). This is the
  # ONLY concurrency knob: N parallel per-arch builds each pass DIVISOR=N so the
  # sum of their job counts still fits one host's RAM.
  local avail_mb divisor
  avail_mb="$(_mem_available_mb)"
  [ -z "${avail_mb}" ] && { printf '%s\n' ""; return 0; }
  divisor="${BUILD_MEM_DIVISOR:-1}"
  [ "${divisor}" -ge 1 ] 2>/dev/null || divisor=1
  printf '%s\n' $(( avail_mb / divisor ))
}

_profile_mb() {
  # Peak per-TU RAM (MB) for a workload profile. Aggressive mode lowers only the
  # LIGHT profiles -- heavy (torch) TUs do not get cheaper on a big host, so the
  # 4GB floor is unconditional. See docs/build-parallelism-memory-tuning.md.
  local aggressive="${AGGRESSIVE_PARALLELISM:-false}"
  case "$1" in
    generic) [ "${aggressive}" = "true" ] && printf '%s\n' "${DEFAULT_MB_PER_JOB:-800}"  || printf '%s\n' "${DEFAULT_MB_PER_JOB:-2000}" ;;
    rust)    [ "${aggressive}" = "true" ] && printf '%s\n' "${RUST_MB_PER_JOB:-1200}"    || printf '%s\n' "${RUST_MB_PER_JOB:-2500}" ;;
    heavy)   printf '%s\n' "${CPP_HEAVY_MB_PER_JOB:-4096}" ;;
    *)       printf '%s\n' "2000" ;;
  esac
}

mem_capped_jobs() {
  # THE core helper: jobs = min(cores, usable_RAM / peak_mb).
  # Usage: mem_capped_jobs <peak_mb> [requested]
  local peak_mb="$1" requested="${2:-}"

  # Hard override wins over everything.
  if [ -n "${PARALLEL_JOBS:-}" ]; then
    printf '%s\n' "${PARALLEL_JOBS}"
    return 0
  fi

  local jobs avail_mb cap
  jobs="$(compute_jobs "${requested}")"
  avail_mb="$(_usable_mem_mb)"
  if [ -n "${avail_mb}" ] && [ "${peak_mb}" -gt 0 ] 2>/dev/null; then
    cap=$(( avail_mb / peak_mb ))
    [ "${cap}" -lt 1 ] && cap=1
    [ "${jobs}" -gt "${cap}" ] 2>/dev/null && jobs="${cap}"
  fi

  [ "${jobs}" -lt 1 ] && jobs=1
  printf '%s\n' "${jobs}"
}

# --- Named wrappers (stable API for callers) --------------------------------
# Each just names a profile; all the logic lives in mem_capped_jobs.

# Generic C/C++ (OpenCV, ONNX, ...). Optional 2nd arg overrides the peak MB.
# Usage: compute_jobs_with_mem_cap [requested] [mb_per_job]
compute_jobs_with_mem_cap() {
  local requested="${1:-}" mb_per_job="${2:-}"
  _auto_aggressive_parallelism
  [ -z "${mb_per_job}" ] && mb_per_job="$(_profile_mb generic)"
  mem_capped_jobs "${mb_per_job}" "${requested}"
}

# Rust/Cargo (gst-plugins-rs) -- heavier link steps than generic C++.
# Usage: compute_rust_jobs [requested]
compute_rust_jobs() {
  _auto_aggressive_parallelism
  mem_capped_jobs "$(_profile_mb rust)" "${1:-}"
}

# Memory-HEAVY C++ (PyTorch/torch_cpu, large LTO). aten/autograd TUs peak
# ~4GB/cc1plus; the generic 2GB estimate overcommits and the OOM-killer kills
# cc1plus (observed: riscv64 litert, 27 jobs x 4GB on a 60GB host). Ignores
# aggressive mode -- these TUs never get cheaper; more RAM just fits more at once.
# Usage: compute_cpp_heavy_jobs [requested]
compute_cpp_heavy_jobs() {
  mem_capped_jobs "$(_profile_mb heavy)" "${1:-}"
}
