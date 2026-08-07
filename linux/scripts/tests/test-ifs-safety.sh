#!/usr/bin/env bash
# Guards against the comma-split-under-strict-IFS bug class.
#
# Many build scripts set IFS=$'\n\t' (strict mode). Under that IFS the popular
# idiom `for x in ${list//,/ }` does NOT split — space is not in IFS — so the
# loop runs ONCE with the whole comma list as a single bogus element. This broke
# the GCC GPG key-set import and the compiler stage's multi-target Python
# staging (both found live on 2026-08-07). The safe repo idiom is
#   IFS=',' read -r -a arr <<< "${list}"   # IFS scoped to the read builtin
# or a `local IFS` immediately before the loop.
#
# This suite (1) proves the two idioms behave as documented and (2) lints the
# script tree so the broken idiom cannot quietly return.
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
# Anti-pattern: an unquoted ${var//,/ } expansion in a for-loop. Every split of
# a comma list must use the read -ra idiom (or local IFS with a justification).
violations="$(grep -rnE 'for [A-Za-z_]+ in \$\{[A-Za-z_]+//,/ \}' "${SCRIPTS_DIR}" \
  --include='*.sh' 2>/dev/null | grep -v "/tests/" || true)"
t_assert_eq "" "${violations}" "found unguarded comma-split for-loops (use IFS=',' read -r -a instead)"

t_summary
