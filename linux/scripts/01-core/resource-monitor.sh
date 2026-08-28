#!/usr/bin/env bash
# Low-overhead CSV sampler of RAM/disk/CPU during the long cross builds, plus a
# summary naming the build activity at each pressure peak.
# Usage, columns and integration: docs/build-resource-monitoring.md.
set -uo pipefail

_rm_now_epoch() { date +%s; }
_rm_iso()       { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ---- one cheap sample of every counter, appended as a CSV row -----------------
_rm_prev_busy=0
_rm_prev_total=0

_rm_cpu_pct() {
  # CPU busy% since the previous call, from /proc/stat aggregate line.
  local a b c d e f g h rest total idle busy pct
  read -r _ a b c d e f g h rest < /proc/stat
  total=$(( a + b + c + d + e + f + g + h ))
  idle=$(( d + e ))
  busy=$(( total - idle ))
  if [ "${_rm_prev_total}" -gt 0 ] && [ "${total}" -gt "${_rm_prev_total}" ]; then
    pct=$(( 100 * (busy - _rm_prev_busy) / (total - _rm_prev_total) ))
  else
    pct=0
  fi
  _rm_prev_busy="${busy}"; _rm_prev_total="${total}"
  printf '%s' "${pct}"
}

_rm_context() {
  # Best-effort "what is building right now": last meaningful line of the active
  # build log, stripped of buildkit's byte-progress noise and CSV-escaped.
  local log="$1"
  [ -n "${log}" ] && [ -r "${log}" ] || { printf '%s' ""; return 0; }
  tail -n 40 "${log}" 2>/dev/null \
    | grep -aE 'Building|Compiling|\[[0-9]+/[0-9]+\]|CC[[:space:]]|CXX[[:space:]]|LD[[:space:]]|LINK|Built target|\[stage |Finished|Installing|error|warning' \
    | grep -avE 'level=(error|warning)|\(\*service\)\.Write' \
    | grep -avE '^\s*$' \
    | tail -n 1 \
    | tr ',"\n\r' '    ' \
    | sed -E 's/^#[0-9]+ [0-9.]+ //; s/[[:space:]]+/ /g' \
    | cut -c1-80
}

_rm_stage() {
  # Coarser phase label: the most recent buildkit stage name (#NN [name ...]) or
  # orchestrator [stage X] marker in the active log; falls back to --label.
  local log="$1" fallback="$2" s
  if [ -n "${log}" ] && [ -r "${log}" ]; then
    s="$(tail -n 200 "${log}" 2>/dev/null \
         | grep -aoE '\[stage [a-z0-9-]+\]|#[0-9]+ \[[a-z0-9-]+ ' \
         | tail -n 1 | grep -oE '[a-z0-9-]+ ?\]?$' | tr -d ' ]')"
  fi
  printf '%s' "${s:-${fallback:-?}}"
}

_rm_active_log() {
  # Explicit --stage-log, else the newest *.log in the dir — preferring one with a
  # sibling `.log.run` marker (MON1: plain newest-*.log picked the orchestrator runlog,
  # so every sample read stage=? and buildkitd stderr).
  local explicit="$1" dir="$2" f
  if [ -n "${explicit}" ]; then printf '%s' "${explicit}"; return 0; fi
  [ -n "${dir}" ] && [ -d "${dir}" ] || { printf '%s' ""; return 0; }
  for f in $(ls -t "${dir}"/*.log 2>/dev/null); do
    [ -f "${f}.run" ] && { printf '%s' "${f}"; return 0; }
  done
  ls -t "${dir}"/*.log 2>/dev/null | head -n 1
}

_rm_sample_loop() {
  local out_dir="$1" run_id="$2" interval="$3" disk_path="$4" stage_log="$5" label="$6" stage_log_dir="$7" watch_pid="$8"
  local csv="${out_dir}/resources-${run_id}.csv"
  mkdir -p "${out_dir}" 2>/dev/null || true
  RM_CSV="${csv}"   # exported for the exit trap's summarizer

  printf 'epoch,iso,elapsed_s,load1,cpu_pct,mem_used_mb,mem_avail_mb,mem_pct,swap_used_mb,disk_avail_gb,disk_pct,compilers,stage,context\n' > "${csv}"

  local start; start="$(_rm_now_epoch)"
  local mt ma st sf load1 cpu memused memavail mempct swapused diskkb_avail diskkb_total diskgb diskpct comp stage ctx now iso elapsed
  _rm_cpu_pct >/dev/null   # prime the CPU delta

  while :; do
    now="$(_rm_now_epoch)"; iso="$(_rm_iso)"; elapsed=$(( now - start ))
    read -r load1 _ < /proc/loadavg
    cpu="$(_rm_cpu_pct)"
    # memory (kB from /proc/meminfo)
    mt=0; ma=0; st=0; sf=0
    while read -r k v _; do
      case "${k}" in
        MemTotal:) mt="${v}" ;; MemAvailable:) ma="${v}" ;;
        SwapTotal:) st="${v}" ;; SwapFree:) sf="${v}" ;;
      esac
    done < /proc/meminfo
    memused=$(( (mt - ma) / 1024 )); memavail=$(( ma / 1024 ))
    mempct=0; [ "${mt}" -gt 0 ] && mempct=$(( 100 * (mt - ma) / mt ))
    swapused=$(( (st - sf) / 1024 ))
    # disk on the build filesystem
    read -r diskkb_total diskkb_avail < <(df -Pk "${disk_path}" 2>/dev/null | awk 'NR==2{print $2, $4}')
    diskgb=$(( ${diskkb_avail:-0} / 1024 / 1024 ))
    diskpct=0; [ "${diskkb_total:-0}" -gt 0 ] && diskpct=$(( 100 * (diskkb_total - diskkb_avail) / diskkb_total ))
    # `pgrep -c` prints "0" AND exits 1 on no match, so `|| true` and never
    # `|| echo 0` — a second 0 would split the CSV row.
    comp="$(pgrep -c -x 'cc1plus|cc1|clang|clang\+\+|rustc|lto1|cc1objplus|go|ld' 2>/dev/null || true)"
    [ -n "${comp}" ] || comp=0
    local active_log; active_log="$(_rm_active_log "${stage_log}" "${stage_log_dir}")"
    stage="$(_rm_stage "${active_log}" "${label}")"
    ctx="$(_rm_context "${active_log}")"

    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,"%s"\n' \
      "${now}" "${iso}" "${elapsed}" "${load1}" "${cpu}" "${memused}" "${memavail}" \
      "${mempct}" "${swapused}" "${diskgb}" "${diskpct}" "${comp}" "${stage}" "${ctx}" >> "${csv}"

    # Self-terminate once the watched build is gone; the EXIT trap writes the summary.
    if [ -n "${watch_pid}" ] && ! kill -0 "${watch_pid}" 2>/dev/null; then
      break
    fi
    sleep "${interval}"
  done
}

# ---- summary: find and explain the peak-pressure moments ----------------------
rm_summarize() {
  local csv="$1"
  [ -r "${csv}" ] || { echo "resource-monitor: no CSV at ${csv}" >&2; return 1; }
  local out="${csv%.csv}.summary.txt"
  local near_oom="${RM_NEAR_OOM_MB:-4096}" low_disk="${RM_LOW_DISK_GB:-20}"

  # dmesg OOM scan (best effort; may be root-gated)
  local oom_hits="n/a (dmesg unreadable)"
  if dmesg >/dev/null 2>&1; then
    oom_hits="$(dmesg 2>/dev/null | grep -ciE 'killed process|out of memory|oom-kill' || echo 0)"
  fi

  awk -F',' -v OFS='' -v near="${near_oom}" -v lowd="${low_disk}" -v oom="${oom_hits}" '
    NR==1 { next }
    {
      n++
      # strip surrounding quotes from context (last field may contain none)
      ctx=$14; gsub(/^"|"$/,"",ctx)
      load=$4+0; cpu=$5+0; mu=$6+0; ma=$7+0; sw=$9+0; dg=$10+0
      dur=$3+0
      if (mu>maxmu){maxmu=mu; mu_t=$2; mu_s=$13; mu_c=ctx; mu_av=ma}
      if (firstma==0 || ma<minma){minma=ma; ma_t=$2; ma_s=$13; ma_c=ctx; firstma=1}
      if (sw>maxsw){maxsw=sw; sw_t=$2; sw_s=$13}
      if (firstdg==0 || dg<mindg){mindg=dg; dg_t=$2; dg_s=$13; dg_c=ctx; firstdg=1}
      if (load>maxload){maxload=load; load_t=$2; load_s=$13}
      if (cpu>maxcpu)  maxcpu=cpu
      if (ma>0 && ma<near) noom++
      if (dg>0 && dg<lowd) ndisk++
      lastdur=dur
    }
    END {
      printf "=== resource-monitor summary ===\n"
      printf "samples=%d  duration=%dm%02ds\n\n", n, int(lastdur/60), lastdur%60
      printf "PEAK MEMORY USE:\n"
      printf "  %d MB used  (only %d MB available)  at %s\n", maxmu, mu_av, mu_t
      printf "  stage=%s  context=%s\n\n", mu_s, mu_c
      printf "MIN MEMORY AVAILABLE (closest to OOM):\n"
      printf "  %d MB free  at %s\n", minma, ma_t
      printf "  stage=%s  context=%s\n\n", ma_s, ma_c
      printf "PEAK SWAP USE: %d MB  at %s  (stage=%s)%s\n\n", maxsw, (maxsw>0?sw_t:"-"), (maxsw>0?sw_s:"-"), (maxsw>0?"":"  [no swapping — good]")
      printf "MIN DISK FREE (build fs):\n"
      printf "  %d GB free  at %s\n", mindg, dg_t
      printf "  stage=%s  context=%s\n\n", dg_s, dg_c
      printf "PEAK LOAD: %.2f  at %s (stage=%s)   PEAK CPU: %d%%\n", maxload, load_t, load_s, maxcpu
      printf "samples below %d MB free RAM (near-OOM): %d\n", near, noom+0
      printf "samples below %d GB free disk: %d\n", lowd, ndisk+0
      printf "kernel OOM-kill events (dmesg): %s\n", oom
    }
  ' "${csv}" | tee "${out}"
  echo "resource-monitor: summary written to ${out}" >&2
}

# ---- entrypoint ---------------------------------------------------------------
main() {
  if [ "${1:-}" = "summarize" ]; then
    shift; rm_summarize "${1:?usage: resource-monitor.sh summarize <csv>}"; return $?
  fi

  local out_dir="${LOG_DIR:-.}" run_id="${CROSS_RUN_ID:-run}" interval=15
  local disk_path="${BUILDKIT_CACHE_DIR:-${HOME:-/}}" stage_log="" stage_log_dir="" label="" watch_pid=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --out-dir)       out_dir="$2"; shift 2 ;;
      --run-id)        run_id="$2"; shift 2 ;;
      --interval)      interval="$2"; shift 2 ;;
      --disk-path)     disk_path="$2"; shift 2 ;;
      --stage-log)     stage_log="$2"; shift 2 ;;
      --stage-log-dir) stage_log_dir="$2"; shift 2 ;;
      --label)         label="$2"; shift 2 ;;
      --watch-pid)     watch_pid="$2"; shift 2 ;;
      --near-oom-mb)   export RM_NEAR_OOM_MB="$2"; shift 2 ;;
      --low-disk-gb)   export RM_LOW_DISK_GB="$2"; shift 2 ;;
      *) echo "resource-monitor: unknown arg '$1'" >&2; return 2 ;;
    esac
  done
  [ -d "${disk_path}" ] || disk_path="/"

  RM_CSV=""
  trap 'ec=$?; [ -n "${RM_CSV}" ] && rm_summarize "${RM_CSV}" >/dev/null 2>&1 || true; exit ${ec}' INT TERM EXIT
  _rm_sample_loop "${out_dir}" "${run_id}" "${interval}" "${disk_path}" "${stage_log}" "${label}" "${stage_log_dir}" "${watch_pid}"
}

main "$@"
