#!/usr/bin/env bash
# A rendezvous for the parallelism suites: jobs that meet ran at once, however loaded the host is.

# meet_peers <dir> <name> <count> [secs]: marks <name> as started, waits up to <secs> (60) for <count> marks; prints met or alone.
meet_peers() {
  local dir="$1" name="$2" count="$3" ticks i=0
  ticks=$(( ${4:-60} * 10 ))
  : > "${dir}/meet.${name}"
  while [ "$(find "${dir}" -maxdepth 1 -name 'meet.*' | wc -l)" -lt "${count}" ]; do
    [ "${i}" -lt "${ticks}" ] || { echo alone; return 1; }
    i=$(( i + 1 ))
    sleep 0.1
  done
  echo met
}
