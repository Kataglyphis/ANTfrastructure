#!/usr/bin/env bash
# verify-shell-eol.sh [<root>] [--staged]: a CR breaks bash in the container. See docs/code-quality-tooling.md#crlf-guard-the-worked-example
set -uo pipefail

_EOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="." column="w" field=2 staged=0
for arg in "$@"; do
  case "${arg}" in
    --staged) staged=1 column="i" field=1 ;;
    -*) printf 'verify-shell-eol.sh: unknown argument %s (expected [<root>] [--staged])\n' "${arg}" >&2; exit 2 ;;
    *) root="${arg}" ;;
  esac
done
cd "${root}" 2>/dev/null && git rev-parse --git-dir >/dev/null 2>&1 \
  || { printf 'verify-shell-eol.sh: %s is not a git checkout\n' "${root}" >&2; exit 2; }

# <column> <field>: the offending tracked shell scripts, one "  <eol>  <path>" line each; a failed git call prints a marker.
_eol_offenders() {
  local list=(git ls-files -z)
  [ "${staged}" -eq 0 ] || list=(git diff --cached --name-only --diff-filter=ACMRT -z)
  "${list[@]}" 2>/dev/null \
    | xargs -0r bash "${_EOL_DIR}/lint-shell.sh" --list-files 2>/dev/null \
    | tr '\n' '\0' \
    | xargs -0r git ls-files --eol -- 2>/dev/null \
    | awk -F'\t' -v n="$2" -v p="$1/" '{ split($1, c, /[ \t]+/)
        if (c[n] == p "crlf" || c[n] == p "mixed" || c[n] == p "-text")
          printf "  %s  %s\n", c[n], $2 }' \
    || echo "__git-ls-files-FAILED__"
}

where="working-tree"; [ "${staged}" -eq 0 ] || where="staged"
offenders="$(_eol_offenders "${column}" "${field}")"
if [ -n "${offenders}" ]; then
  printf 'CRLF %s line endings detected in tracked shell script(s):\n%s\n' "${where}" "${offenders}"
  if [ "${staged}" -eq 0 ]; then
    printf 'Fix (re-materialize LF from the index): rm <file> && git checkout -- <file>\n'
  else
    printf 'Fix: convert the file to LF (sed -i "s/\\r$//" <file>) and git add it again\n'
  fi
  exit 1
fi
[ "${staged}" -eq 1 ] || where="in the working tree"
printf 'no %s/crlf, %s/mixed or %s/-text shell scripts %s\n' "${column}" "${column}" "${column}" "${where}"
