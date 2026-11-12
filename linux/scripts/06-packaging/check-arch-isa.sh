#!/usr/bin/env bash
# The riscv64 and amd64 ISA gates; the amd64 one grades facts about the image, never each shipped ELF. docs/amd64-x86-64-v3-baseline.md#the-gates

# Sourced by smoke-runtime-image.sh; sets no shell options.

# riscv64 ISA gate: one OK|BAD|SKIP <lib> <attr> line per shipped object.
_rvv_verdicts() {
  local probe="$1" lib attr n=0 cc vcc=0
  cc="$(_smoke_probe_values "${probe}" RVCC | head -1)"
  # Demand vector only once the image's own toolchain defaults to it; before that plain objects are expected.
  case "${cc}" in rva23*|*gcv*|*_v|*_v_*) vcc=1 ;; esac
  while read -r lib attr; do
    [ -n "${lib}" ] || continue
    n=$((n + 1))
    case "${attr}" in
      "")        printf 'SKIP %s no ISA attribute could be read\n' "${lib}" ;;
      *_v1p0*)   printf 'OK %s %s\n' "${lib}" "${attr}" ;;
      *)         if [ "${vcc}" = "1" ]; then printf 'BAD %s %s\n' "${lib}" "${attr}"
                 else printf 'OLD %s %s\n' "${lib}" "${attr}"; fi ;;
    esac
  done < <(_smoke_probe_values "${probe}" RVARCH)
  [ "${n}" -gt 0 ] || printf 'NONE - -\n'
}

_rvv_verdict_line() {
  _shipped_verdict_line "$1" \
    "RVV: @1@ was built WITHOUT the vector extension (@2@) -- the image's own glibc requires it, so this object is below the platform baseline. See docs/riscv64-rva23-baseline.md" \
    "@1@ predates the RVA23 switch (@2@); the image's own gcc has no vector default either" \
    "RVV: the probe found none of the objects it checks -- a vacuous pass, not a green image"
}

# C: riscv64 objects must carry the vector extension Ubuntu's own userland requires.
check_riscv64_isa() {
  _shipped_arch_gate riscv64 "$2" "C: riscv64 ISA of the shipped objects" "riscv64 ISA" \
    "RVV: all " " checked object(s) carry v1p0" _rvv_verdicts _rvv_verdict_line
}

# amd64 only: the compiler default, what it predefines, OpenCV's baseline and the loader's verdict on this CPU.
_probe_amd64_baseline() {
  cat <<'PROBE'
if [ -x /lib64/ld-linux-x86-64.so.2 ]; then
  printf 'X86CC %s\n' "$(gcc -v 2>&1 | grep -oE 'with-arch=[a-z0-9_-]+' | head -1 | cut -d= -f2)"
  printf 'X86DEF %s\n' "$(printf '' | cc -dM -E -x c - 2>/dev/null | grep -cE '^#define __(AVX2|FMA|BMI2)__ 1')"
  printf 'X86OCV %s\n' "$("$py" -c 'import cv2,re;m=re.search(r"Baseline:\s*(.*)",cv2.getBuildInformation());print("_".join(m.group(1).split()) if m else "")' 2>/dev/null)"
  printf 'X86LD %s\n' "$(/lib64/ld-linux-x86-64.so.2 --help 2>/dev/null | grep -e 'x86-64-v3' | head -1 | tr -s ' ' '_')"
fi
PROBE
}

# One OK|BAD|SKIP <fact> <value> line per fact, or OLD when the image's own gcc predates the switch.
_x86_baseline_verdicts() {
  local probe="$1" cc defs ocv ld
  if [ "$(_smoke_probe_values "${probe}" X86CC | wc -l)" -eq 0 ]; then printf 'NONE - -\n'; return 0; fi
  cc="$(_smoke_probe_values "${probe}" X86CC | head -1)"
  if [ "${cc}" != x86-64-v3 ]; then printf 'OLD cc %s\n' "${cc:-generic}"; return 0; fi
  printf 'OK cc %s\n' "${cc}"
  defs="$(_smoke_probe_values "${probe}" X86DEF | head -1)"
  if [ "${defs}" = 3 ]; then printf 'OK defines 3\n'; else printf 'BAD defines %s-of-3\n' "${defs:-0}"; fi
  ocv="$(_smoke_probe_values "${probe}" X86OCV | head -1)"
  case "${ocv}" in
    "")     printf 'SKIP opencv no-build-information\n' ;;
    *AVX2*) printf 'OK opencv %s\n' "${ocv}" ;;
    *)      printf 'BAD opencv %s\n' "${ocv}" ;;
  esac
  ld="$(_smoke_probe_values "${probe}" X86LD | head -1)"
  case "${ld}" in
    *supported*) printf 'OK loader %s\n' "${ld}" ;;
    *)           printf 'BAD loader %s\n' "${ld:-no-x86-64-v3-line}" ;;
  esac
  return 0
}

_x86_baseline_verdict_line() {
  _shipped_verdict_line "$1" \
    "x86-64-v3: @1@ disagrees with the image's own compiler default (@2@). See docs/amd64-x86-64-v3-baseline.md" \
    "the image's gcc defaults to @2@, not x86-64-v3: it was built before the baseline switch" \
    "x86-64-v3: the probe printed no amd64 baseline fact -- a vacuous pass, not a green image"
}

# On amd64 the compiler default, OpenCV's baseline and the loader's CPU verdict must agree on x86-64-v3.
check_amd64_isa() {
  _shipped_arch_gate amd64 "$2" "C2: amd64 baseline of the image's compiler, OpenCV and loader" "amd64 baseline" \
    "x86-64-v3: " " baseline fact(s) agree" _x86_baseline_verdicts _x86_baseline_verdict_line
}
