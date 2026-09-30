#!/usr/bin/env bash
# parallelism.sh - build parallelism helpers (CPU quota + memory cap)
[ -n "${_PARALLELISM_SH_LOADED:-}" ] && return 0
_PARALLELISM_SH_LOADED=1
# Peak MB per job are calibrated, not averages. docs/build-parallelism-memory-tuning.md#how-to-tune-safely-procedure-for-an-agent

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

# Remaining MB under one cgroup generation; non-zero when it sets no limit (v2 `max`, v1 a near-infinite number).
_cgroup_remaining_mb_from() {
  local max_file="$1" current_file="$2" max current="" remaining
  [ -r "${max_file}" ] || return 1
  max="$(cat "${max_file}" 2>/dev/null || printf '')"
  # Non-numeric means no usable limit; it would also kill an errexit caller in the arithmetic below.
  case "${max}" in ''|*[!0-9]*) return 1 ;; esac
  { [ "${max}" -gt 0 ] && [ "${max}" -lt 9223372036854771712 ]; } 2>/dev/null || return 1

  [ -r "${current_file}" ] && current="$(cat "${current_file}" 2>/dev/null || printf '')"
  if [ -n "${current}" ] && [ "${current}" -ge 0 ] 2>/dev/null; then
    remaining=$(( max - current ))
    [ "${remaining}" -lt 0 ] 2>/dev/null && remaining=0
    printf '%s\n' $(( remaining / 1024 / 1024 ))
    return 0
  fi
  printf '%s\n' $(( max / 1024 / 1024 ))
}

# Remaining cgroup MB, v2 then v1, empty when unlimited; CGROUP_ROOT lets tests redirect the kernel paths.
_cgroup_mem_remaining_mb() {
  local root="${CGROUP_ROOT:-/sys/fs/cgroup}"
  _cgroup_remaining_mb_from "${root}/memory.max" "${root}/memory.current" && return 0
  _cgroup_remaining_mb_from "${root}/memory/memory.limit_in_bytes" \
                            "${root}/memory/memory.usage_in_bytes" && return 0
  printf '%s\n' ""
}

_auto_aggressive_parallelism() {
  # Auto-on at >= 16 GB available; an explicit true/false wins.
  case "${AGGRESSIVE_PARALLELISM:-}" in true|false) return 0 ;; esac
  local avail_mb
  avail_mb="$(_mem_available_mb)"
  if [ -n "${avail_mb}" ] && [ "${avail_mb}" -ge 16384 ] 2>/dev/null; then
    export AGGRESSIVE_PARALLELISM=true
  fi
}

_usable_mem_mb() {
  # The one concurrency knob: N parallel builds each pass BUILD_MEM_DIVISOR=N so together they fit the host.
  local avail_mb divisor
  avail_mb="$(_mem_available_mb)"
  [ -z "${avail_mb}" ] && { printf '%s\n' ""; return 0; }
  divisor="${BUILD_MEM_DIVISOR:-1}"
  [ "${divisor}" -ge 1 ] 2>/dev/null || divisor=1
  printf '%s\n' $(( avail_mb / divisor ))
}

_profile_mb() {
  # Peak per-TU MB; aggressive mode lowers only light profiles, since heavy (torch) TUs never get cheaper.
  local aggressive="${AGGRESSIVE_PARALLELISM:-false}"
  case "$1" in
    generic) [ "${aggressive}" = "true" ] && printf '%s\n' "${DEFAULT_MB_PER_JOB:-800}"  || printf '%s\n' "${DEFAULT_MB_PER_JOB:-2000}" ;;
    rust)    [ "${aggressive}" = "true" ] && printf '%s\n' "${RUST_MB_PER_JOB:-1200}"    || printf '%s\n' "${RUST_MB_PER_JOB:-2500}" ;;
    heavy)   printf '%s\n' "${CPP_HEAVY_MB_PER_JOB:-4096}" ;;
    *)       printf '%s\n' "2000" ;;
  esac
}

mem_capped_jobs() {
  # mem_capped_jobs <peak_mb> [requested]: min(cores, usable RAM / peak_mb).
  local peak_mb="$1" requested="${2:-}"

  # Only a valid PARALLEL_JOBS overrides; 0 or junk would otherwise reach make -j0.
  if [ -n "${PARALLEL_JOBS:-}" ]; then
    case "${PARALLEL_JOBS}" in
      *[!0-9]*)
        printf 'WARNING: ignoring non-numeric PARALLEL_JOBS=%s\n' "${PARALLEL_JOBS}" >&2 ;;
      *)
        if [ "${PARALLEL_JOBS}" -ge 1 ] 2>/dev/null; then
          printf '%s\n' "${PARALLEL_JOBS}"
          return 0
        fi
        printf 'WARNING: ignoring PARALLEL_JOBS=%s (< 1)\n' "${PARALLEL_JOBS}" >&2 ;;
    esac
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

# Named wrappers (stable API): each only picks a profile

# Generic C/C++: compute_jobs_with_mem_cap [requested] [mb_per_job]
compute_jobs_with_mem_cap() {
  local requested="${1:-}" mb_per_job="${2:-}"
  _auto_aggressive_parallelism
  [ -z "${mb_per_job}" ] && mb_per_job="$(_profile_mb generic)"
  mem_capped_jobs "${mb_per_job}" "${requested}"
}

# Rust/Cargo: heavier link steps than generic C++.
compute_rust_jobs() {
  _auto_aggressive_parallelism
  mem_capped_jobs "$(_profile_mb rust)" "${1:-}"
}

# Memory-heavy C++ (torch, large LTO): ~4 GB per cc1plus, so the generic estimate would OOM.
compute_cpp_heavy_jobs() {
  mem_capped_jobs "$(_profile_mb heavy)" "${1:-}"
}
