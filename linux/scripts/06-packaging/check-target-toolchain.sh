#!/usr/bin/env bash
# check-target-toolchain.sh <arch>: every compiler and assembler on the runtime's PATH is built for <arch>, or the build stops here (2026-10-21).
set -uo pipefail

arch="${1:?usage: check-target-toolchain.sh <amd64|arm64|riscv64>}"
case "${arch}" in
  amd64)   want='X86-64' ;;
  arm64)   want='AArch64' ;;
  riscv64) want='RISC-V' ;;
  *) echo "check-target-toolchain: no ELF machine known for '${arch}'" >&2; exit 2 ;;
esac

# Cross-built toolchains are host programs (x86-64) that emit target code: a riscv64 runtime that runs one fails inside a compile, far from its cause.
tools=()
for name in as ld sccache; do
  p="$(command -v "${name}" 2>/dev/null || true)"
  [ -n "${p}" ] && tools+=("${p}")
done
for name in c++ g++ cc gcc clang clang++; do
  p="$(command -v "${name}" 2>/dev/null || true)"
  [ -n "${p}" ] && tools+=("$(readlink -f "${p}")")
done
for p in /opt/gcc-*/bin/c++ /usr/local/llvm-target/bin/clang; do
  [ -e "${p}" ] && tools+=("$(readlink -f "${p}")")
done

bad=0
seen=" "
for t in "${tools[@]}"; do
  case "${seen}" in *" ${t} "*) continue ;; esac
  seen="${seen}${t} "
  # A driver script is no binary: the ELF it runs is checked where it is listed.
  if [ "$(head -c 2 "${t}" 2>/dev/null)" = "#!" ]; then
    continue
  fi
  machine="$(readelf -h "${t}" 2>/dev/null | sed -n 's/^ *Machine: *//p')"
  if [ -z "${machine}" ]; then
    echo "check-target-toolchain: ${t} is not an ELF file we can read" >&2
    bad=$((bad + 1))
  elif [ "${machine}" != "${want}" ] && ! printf '%s' "${machine}" | grep -qi -e "${want}"; then
    echo "check-target-toolchain: ${t} is '${machine}', the ${arch} runtime needs ${want}" >&2
    bad=$((bad + 1))
  fi
  # The images are glibc: a binary asking for the musl loader cannot start (sccache, 2026-10-21).
  loader="$(readelf -l "${t}" 2>/dev/null | sed -n 's/.*Requesting program interpreter: //p' | tr -d ']')"
  case "${loader}" in
    *musl*)
      echo "check-target-toolchain: ${t} asks for the musl loader ${loader}; this glibc ${arch} image has none" >&2
      bad=$((bad + 1)) ;;
  esac
done

if [ "${bad}" -ne 0 ]; then
  echo "check-target-toolchain: ${bad} host tool(s) on the ${arch} PATH; a compile here would fail inside sccache or cc1plus" >&2
  exit 1
fi
echo "check-target-toolchain: ${#tools[@]} tool(s) on the ${arch} PATH are ${want}"
