#!/usr/bin/env bash
# check-flutter-unwinder-order.sh <executable>...: libgcc_s must define _Unwind_RaiseException first; a library dlopen()ed later is not seen. See docs/failure-modes.md#a-flutter-350-linux-app-aborts-at-its-first-c-exception
set -euo pipefail

usage() {
  printf 'usage: %s <executable>...\n' "${0##*/}"
  printf 'Fails unless libgcc_s.so.1 is the first object in ldd load order that defines _Unwind_RaiseException.\n'
}

case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
  "")
    usage >&2
    exit 2
    ;;
esac
for tool in ldd readelf; do
  if ! command -v "${tool}" > /dev/null 2>&1; then
    printf 'check-flutter-unwinder-order: %s is required\n' "${tool}" >&2
    exit 2
  fi
done

# first_definer <ldd listing>: the soname of the first loaded object that defines _Unwind_RaiseException, or nothing.
first_definer() {
  local name path syms
  # ldd lists the objects in load order, which is the order the global symbol lookup searches.
  while read -r name path; do
    if ! syms="$(readelf --dyn-syms -W "${path}" 2>&1)"; then
      printf 'check-flutter-unwinder-order: readelf failed on %s:\n%s\n' "${path}" "${syms}" >&2
      return 1
    fi
    if awk '$7 != "UND" && $8 ~ /^_Unwind_RaiseException(@|$)/ {hit = 1} END {exit !hit}' <<< "${syms}"; then
      printf '%s\n' "${name}"
      return 0
    fi
  done < <(awk '$2 == "=>" && $3 ~ /^\// {print $1, $3}' <<< "$1")
  return 0
}

# check_one <executable>: prints the verdict; returns 1 on a wrong order or an incomplete listing.
check_one() {
  local exe="$1" listing first
  if [ ! -f "${exe}" ]; then
    printf 'check-flutter-unwinder-order: no executable at %s\n' "${exe}" >&2
    return 1
  fi
  # bundle-loader.sh --beside leaves a launcher that starts <name>.bin, so that ELF's load order is the one that counts.
  if [ "$(head -c 2 -- "${exe}")" = '#!' ]; then
    if [ ! -f "${exe}.bin" ]; then
      printf 'check-flutter-unwinder-order: %s is a script with no %s.bin beside it to grade\n' "${exe}" "${exe##*/}" >&2
      return 1
    fi
    exe="${exe}.bin"
  fi
  if ! listing="$(ldd "${exe}" 2>&1)"; then
    printf 'check-flutter-unwinder-order: ldd failed on %s:\n%s\n' "${exe}" "${listing}" >&2
    return 1
  fi
  # An unresolved library hides its symbols, so the order would be graded on a partial list.
  if [[ "${listing}" == *"not found"* ]]; then
    printf 'check-flutter-unwinder-order: %s has unresolved libraries:\n%s\n' "${exe}" "$(awk '/not found/' <<< "${listing}")" >&2
    return 1
  fi
  if ! first="$(first_definer "${listing}")"; then
    return 1
  fi
  case "${first}" in
    libgcc_s.so*)
      printf 'unwinder order: %s defines _Unwind_RaiseException first for %s\n' "${first}" "${exe}"
      return 0
      ;;
    "")
      printf 'check-flutter-unwinder-order: nothing in the load order of %s defines _Unwind_RaiseException\n' "${exe}" >&2
      return 1
      ;;
    *)
      printf 'check-flutter-unwinder-order: %s defines _Unwind_RaiseException ahead of libgcc_s.so.1 for %s,\n' "${first}" "${exe}" >&2
      printf '  so its first C++ throw or Rust panic aborts. Call kataglyphis_flutter_unwinder_first(<runner>) before the runner links flutter.\n' >&2
      return 1
      ;;
  esac
}

rc=0
for exe in "$@"; do
  check_one "${exe}" || rc=1
done
exit "${rc}"
