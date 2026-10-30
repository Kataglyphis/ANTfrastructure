#!/usr/bin/env bash
# ELF_NEEDED_API=1
# List direct NEEDED entries only after readelf has reported the complete dynamic section.

elf_dynamic_needed() {
  local file="${1:?ELF file required}" dynamic entries
  if ! dynamic="$(LC_ALL=C readelf -d "${file}" 2>&1)"; then
    printf 'ERROR: cannot inspect ELF dynamic section: %s\n%s\n' "${file}" "${dynamic}" >&2
    return 1
  fi
  case "${dynamic}" in
    'There is no dynamic section in this file.'|$'\nThere is no dynamic section in this file.') return 0 ;;
    *'There is no dynamic section'*)
      printf 'ERROR: conflicting ELF dynamic section output: %s\n' "${file}" >&2
      return 1 ;;
  esac
  if ! entries="$(printf '%s\n' "${dynamic}" | awk '
    /Dynamic section at offset .* contains [0-9]+ entries:/ {
      header++; text=$0; sub(/^.* contains /, "", text); sub(/ entries:.*/, "", text); expected=text+0; next
    }
    /^[[:space:]]*0x[0-9a-fA-F]+[[:space:]]+\(/ {
      count++; last=$2
      if ($2 == "(NEEDED)") {
        if ($0 !~ /Shared library: \[[^][]+\]/) { invalid=1; next }
        text=$0; sub(/^.*Shared library: \[/, "", text); sub(/\].*$/, "", text)
        if (text ~ /[[:space:]]/) { invalid=1; next }
        names[++names_count]=text
      }
    }
    END {
      if (header != 1 || invalid || count != expected || last != "(NULL)") exit 1
      for (i=1; i<=names_count; i++) print names[i]
    }')"; then
    printf 'ERROR: incomplete ELF dynamic section: %s\n' "${file}" >&2
    return 1
  fi
  [ -z "${entries}" ] || printf '%s\n' "${entries}"
}
