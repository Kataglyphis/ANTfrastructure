#!/usr/bin/env bash
# Under IFS=$'\n\t' a `${list//,/ }` loop runs once; see AGENTS.md § Shell safety conventions
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${TESTS_DIR}/.." && pwd)"
source "${TESTS_DIR}/test-harness.sh"

# ---------------------------------------------------------------------------
t_case "documented failure mode: \${list//,/ } does not split under IFS=\$'\\n\\t'"
count="$(bash -c 'set -u; IFS=$'"'"'\n\t'"'"'; x="a,b,c"; n=0; for i in ${x//,/ }; do n=$((n+1)); done; echo $n')"
t_assert_eq "1" "${count}" "the broken idiom must produce exactly one bogus iteration"

t_case "safe idiom: IFS=',' read -ra splits and leaks nothing"
out="$(bash -c 'set -u; IFS=$'"'"'\n\t'"'"'
  x="a,b,c"; declare -a t=(); IFS="," read -r -a t <<< "$x"
  printf "%s;" "${#t[@]}"; [ "$IFS" = "$(printf "\n\t")" ] && printf "ifs-intact"')"
t_assert_eq "3;ifs-intact" "${out}"

# ---------------------------------------------------------------------------
t_case "no unguarded comma-to-space split loops in linux/scripts"
# Comma lists split with `IFS=',' read -r -a`, or a justified local IFS.
violations="$(grep -rnE 'for [A-Za-z_]+ in \$\{[A-Za-z_]+//,/ \}' "${SCRIPTS_DIR}" \
  --include='*.sh' 2>/dev/null | grep -v "/tests/" || true)"
t_assert_eq "" "${violations}" "found unguarded comma-split for-loops (use IFS=',' read -r -a instead)"

t_summary
