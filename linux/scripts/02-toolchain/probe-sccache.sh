#!/usr/bin/env bash
# ==============================================================================
# probe-sccache.sh — does sccache actually work for THIS chain's compilers?
#
# WHY THIS EXISTS (2026-08-26, the ccache->sccache switch)
# -------------------------------------------------------
# ccache and sccache differ in a way that matters more than hit rate: on a
# compiler it cannot identify, sccache does NOT fall through to running it.
# server.rs returns UnsupportedCompiler and the client turns that into
# `bail!("Compiler not supported")` — a non-zero exit, i.e. a BUILD BREAK.
# ccache in the same position simply execs the compiler.
#
# This chain feeds a compiler launcher several shapes that are not a plain
# /usr/bin/gcc:
#   * triplet-prefixed cross compilers      (aarch64-linux-gnu-gcc)
#   * generated bash wrapper scripts        (cross-gcc.sh writes them)
#   * a compiler reached through -B         (llvm-cross.sh)
# The -B case is an OPEN upstream bug (mozilla/sccache#1102, since 2022):
# detection runs `<compiler> -E` without -B, so the compiler cannot find cc1.
#
# Discovering that at hour 9 of a three-lane from-base rebuild is the expensive
# way to find out. This probe costs seconds and answers it up front.
#
# It checks TWO things per compiler, because either alone is misleading:
#   1. the compile SUCCEEDS through sccache (no UnsupportedCompiler bail), and
#   2. sccache actually CACHED it — a compile that silently falls back to
#      "non-cacheable" passes check 1 while caching nothing, which is exactly
#      the silent-cache-loss failure this migration risks.
#
# USAGE
#   bash linux/scripts/02-toolchain/probe-sccache.sh              # probe what is present
#   bash .../probe-sccache.sh gcc aarch64-linux-gnu-gcc           # probe specific ones
#   PROBE_STRICT=1 bash .../probe-sccache.sh                      # non-zero exit on any failure
#
# Exit: 0 = every probed compiler is usable and caching (or PROBE_STRICT unset),
#       1 = at least one compiler failed and PROBE_STRICT=1.
# ==============================================================================
set -uo pipefail

STRICT="${PROBE_STRICT:-0}"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

pass=0; fail=0; nocache=0

say()  { printf '[probe-sccache] %s\n' "$*"; }
ok()   { printf '  \033[0;32mOK\033[0m      %s\n' "$*"; }
bad()  { printf '  \033[0;31mFAIL\033[0m    %s\n' "$*"; }
meh()  { printf '  \033[0;33mNOCACHE\033[0m %s\n' "$*"; }

command -v sccache >/dev/null 2>&1 || { say "sccache not found — nothing to probe"; exit 0; }
say "sccache: $(sccache --version 2>/dev/null || echo unknown)"

export SCCACHE_IDLE_TIMEOUT="${SCCACHE_IDLE_TIMEOUT:-0}"
export SCCACHE_ERROR_LOG="${SCCACHE_ERROR_LOG:-/tmp/sccache-probe.log}"
sccache --start-server >/dev/null 2>&1 || true
if ! sccache --show-stats >/dev/null 2>&1; then
  say "sccache server does not answer — this alone would break every compile"
  exit 1
fi

cat > "${WORK}/probe.c" <<'EOF'
#include <stdio.h>
int probe_main(void) { return 0; }
EOF

# Total "cache writes" counter, whatever sccache calls it in this version.
_writes() {
  sccache --show-stats 2>/dev/null \
    | awk -F'[[:space:]][[:space:]]+' '/[Cc]ache write|Cache hits|Compile requests executed/ {gsub(/[^0-9]/,"",$2); s+=$2} END{print s+0}'
}

probe_one() {
  local cc="$1"; shift
  local extra=("$@")
  local before after out rc

  before="$(_writes)"
  out="$(sccache "${cc}" "${extra[@]}" -c "${WORK}/probe.c" -o "${WORK}/probe-$$.o" 2>&1)"
  rc=$?
  rm -f "${WORK}/probe-$$.o"

  if [ "${rc}" -ne 0 ]; then
    bad "${cc} ${extra[*]}"
    printf '          %s\n' "$(printf '%s' "${out}" | head -3 | tr '\n' ' ')"
    fail=$((fail + 1))
    return 1
  fi

  after="$(_writes)"
  if [ "${after}" -gt "${before}" ]; then
    ok "${cc} ${extra[*]}"
    pass=$((pass + 1))
  else
    # Compiles fine but sccache recorded nothing: the silent failure mode.
    meh "${cc} ${extra[*]} — compiled, but sccache recorded no cache activity"
    nocache=$((nocache + 1))
  fi
  return 0
}

# ── which compilers to probe ─────────────────────────────────────────────────
declare -a CCS=()
if [ "$#" -gt 0 ]; then
  CCS=("$@")
else
  for c in gcc g++ clang clang++ \
           aarch64-linux-gnu-gcc aarch64-linux-gnu-g++ \
           riscv64-linux-gnu-gcc riscv64-linux-gnu-g++; do
    command -v "${c}" >/dev/null 2>&1 && CCS+=("${c}")
  done
  # Generated wrapper scripts, if this image has them staged.
  for w in /usr/local/bin/cross-gcc.sh /tmp/cross-wrappers/*gcc*; do
    [ -x "${w}" ] && CCS+=("${w}")
  done
fi

[ "${#CCS[@]}" -gt 0 ] || { say "no compilers found to probe"; exit 0; }

say "probing ${#CCS[@]} compiler(s)"
for cc in "${CCS[@]}"; do
  probe_one "${cc}"
done

# The -B shape, which is the one with the open upstream bug. Only meaningful
# when a staged toolchain dir exists to point at.
for bdir in /usr/local/llvm-target/bin /usr/local/gcc-*/bin; do
  if [ -d "${bdir}" ] && command -v gcc >/dev/null 2>&1; then
    say "probing the -B shape (mozilla/sccache#1102)"
    probe_one gcc "-B${bdir}"
    break
  fi
done

say "result: ${pass} cached, ${nocache} compiled-but-uncached, ${fail} failed"
sccache --show-stats 2>/dev/null | head -8

if [ "${fail}" -gt 0 ] && [ "${STRICT}" = "1" ]; then
  say "FAILURES present and PROBE_STRICT=1 — do not launch a full rebuild on this"
  exit 1
fi
if [ "${nocache}" -gt 0 ] && [ "${STRICT}" = "1" ]; then
  say "compilers that cache NOTHING are a silent slowdown, not an error — review before launching"
fi
exit 0
