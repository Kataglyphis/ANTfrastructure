#!/usr/bin/env bash
# PIE, RELRO, BIND_NOW, the stack protector and _FORTIFY_SOURCE in shipped ELF files. See docs/linux-build-basics.md#the-elf-hardening-gate
set -euo pipefail

# Usage: verify-elf-hardening.sh SPEC...; SPEC is FILE[:executable|library][:fortify|no-fortify], by default executable and fortify.
if [[ $# -eq 0 ]]; then
  echo 'usage: verify-elf-hardening.sh FILE[:executable|library][:fortify|no-fortify]...' >&2
  exit 2
fi
failures=0

fail() {
  printf 'hardening FAIL: %s\n' "$*" >&2
  failures=$((failures + 1))
}

undefined_imports() {
  LC_ALL=C readelf --dyn-syms -W "$1" | awk '$7 == "UND" && $8 != "" { sub(/@.*/, "", $8); print $8 }'
}

# Usage: check_elf FILE KIND FORTIFY; one line per ELF, ok with what it found, or one FAIL line per missing property.
check_elf() {
  local file="$1" kind="$2" fortify="$3" header program dynamic imports fortified verdict="" before="${failures}"
  header="$(LC_ALL=C readelf -hW "${file}" 2>/dev/null)" || { fail "${file}: not an ELF file"; return 0; }
  program="$(LC_ALL=C readelf -lW "${file}")" || { fail "${file}: readelf -l failed"; return 0; }
  dynamic="$(LC_ALL=C readelf -dW "${file}")" || { fail "${file}: readelf -d failed"; return 0; }
  imports="$(undefined_imports "${file}")" || { fail "${file}: readelf --dyn-syms failed"; return 0; }
  if [[ "${kind}" == executable ]]; then
    if grep -Eq '^ *Type: +DYN ' <<< "${header}" && grep -Eq '^ *INTERP ' <<< "${program}"; then
      verdict+=" PIE"
    else
      fail "${file}: not PIE (needs ELF type DYN and an INTERP segment)"
    fi
  fi
  if grep -Eq '^ *GNU_RELRO ' <<< "${program}"; then verdict+=" RELRO"; else fail "${file}: no GNU_RELRO segment (-z relro)"; fi
  if grep -Eq '\(FLAGS\).*\bBIND_NOW\b|\(FLAGS_1\).*\bNOW\b' <<< "${dynamic}"; then
    verdict+=" BIND_NOW"
  else
    fail "${file}: no BIND_NOW (DT_FLAGS BIND_NOW or DT_FLAGS_1 NOW, -z now)"
  fi
  if grep -qx '__stack_chk_fail' <<< "${imports}"; then
    verdict+=" __stack_chk_fail"
  else
    fail "${file}: no __stack_chk_fail import (stack protector)"
  fi
  # A binary that calls nothing _FORTIFY_SOURCE can bound imports no __*_chk: its spec says no-fortify.
  fortified="$(grep -E -m 1 '^__[A-Za-z0-9_]+_chk$' <<< "${imports}" || true)"
  if [[ -n "${fortified}" ]]; then
    verdict+=" ${fortified}"
  elif [[ "${fortify}" == fortify ]]; then
    fail "${file}: no __*_chk import (_FORTIFY_SOURCE)"
  fi
  if [[ ${failures} -eq ${before} ]]; then printf 'hardening ok: %s:%s\n' "${file}" "${verdict}"; fi
}

for spec in "$@"; do
  IFS=: read -r file kind fortify extra <<< "${spec}"
  kind="${kind:-executable}" fortify="${fortify:-fortify}"
  if [[ -n "${extra:-}" || ! "${kind}" =~ ^(executable|library)$ || ! "${fortify}" =~ ^(fortify|no-fortify)$ ]]; then
    printf 'verify-elf-hardening.sh: bad spec %s (FILE[:executable|library][:fortify|no-fortify])\n' "${spec}" >&2
    exit 2
  fi
  [[ -f "${file}" ]] || { fail "${file}: no such file"; continue; }
  check_elf "${file}" "${kind}" "${fortify}"
done

if [[ ${failures} -gt 0 ]]; then
  printf 'hardening: %d check(s) failed\n' "${failures}" >&2
  exit 1
fi
printf 'hardening: %d ELF file(s) passed\n' "$#"
