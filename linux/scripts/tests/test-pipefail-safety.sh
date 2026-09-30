#!/usr/bin/env bash
# Under pipefail, `producer | grep -q` fails when the match is FOUND early: the producer loses the pipe.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${TESTS_DIR}/.." && pwd)"
source "${TESTS_DIR}/test-harness.sh"

# Part 1: seq 300000 outgrows any pipe buffer, so the producer is always still writing when grep -q exits.

# rc is 141 under default SIGPIPE but 1 where it is inherited as ignored (GitHub runners): assert non-zero.
t_case "pipefail + EARLY match: pipeline reports failure (producer lost the pipe)"
bash -c 'set -o pipefail; seq 300000 | grep -q "^1$"' 2>/dev/null; rc=$?
case "${rc}" in
  141) _early="reproduced" ; _early_kind="killed by SIGPIPE" ;;
  1)   _early="reproduced" ; _early_kind="EPIPE write error (SIGPIPE ignored)" ;;
  *)   _early="rc=${rc}"   ; _early_kind="NOT REPRODUCED" ;;
esac
t_assert_eq "reproduced" "${_early}" \
  "a FOUND symbol must reproduce the false-failure (grep quits, producer loses the pipe) — ${_early_kind}"

t_case "same early match WITHOUT pipefail: 0 — pipefail is the trigger"
bash -c 'seq 300000 | grep -q "^1$"' 2>/dev/null; rc=$?
t_assert_eq "0" "${rc}" "without pipefail the pipeline takes grep's rc"

t_case "pipefail + match at EOF: grep drains everything, pipeline is 0"
bash -c 'set -o pipefail; seq 300000 | grep -q "^300000$"'; rc=$?
t_assert_eq "0" "${rc}" "a late match lets the producer finish — the bug hides"

t_case "pipefail + NO match: grep's own rc 1, producer unharmed"
bash -c 'set -o pipefail; seq 300000 | grep -q ZZZ_NO_SUCH_LINE'; rc=$?
t_assert_eq "1" "${rc}" "the absent-symbol direction masks the bug (grep drains)"

t_case "safe repo idiom: capture-then-case survives set -euo pipefail"
out="$(bash -c 'set -euo pipefail
  syms="$(seq 300000)"
  case "${syms}" in *"299999"*) echo SAFE ;; *) echo MISSED ;; esac')"
rc=$?
t_assert_eq "0" "${rc}" "no pipe, no SIGPIPE"
t_assert_eq "SAFE" "${out}"

# Part 2: only the unbounded ELF inspectors nm/objdump/ldd are flagged; bounded producers cannot outlive grep.

# _scan_pipefail_grepq <root>: "file:line:code" per hit; skips non-pipefail files, tests/, comments, `-print -quit`.
_UNBOUNDED_GREPQ_RE='(^|[^[:alnum:]_./-])(nm|objdump|ldd)[[:space:]][^|]*\|[[:space:]]*grep[[:space:]]+-q'
_scan_pipefail_grepq() {
  local root="$1" f hit code stripped
  while IFS= read -r f; do
    grep -qE 'set[[:space:]]+-[A-Za-z]*o[[:space:]]+pipefail' "${f}" || continue
    while IFS= read -r hit; do
      code="${hit#*:}"
      stripped="${code#"${code%%[![:space:]]*}"}"
      case "${stripped}" in '#'*) continue ;; esac
      case "${code}" in *'-print -quit'*) continue ;; esac
      printf '%s:%s\n' "${f}" "${hit}"
    done < <(grep -nE "${_UNBOUNDED_GREPQ_RE}" "${f}" 2>/dev/null || true)
  done < <(find "${root}" -name '*.sh' -type f ! -path '*/tests/*' 2>/dev/null | sort)
}

# Self-test first: a lint that silently matches nothing is worse than no lint.
_fixdir="$(mktemp -d)"
trap 'rm -rf "${_fixdir}"' EXIT
cat >"${_fixdir}/bad.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
nm -D /usr/local/lib/libfoo.so | grep -q SomeSymbol && echo present
EOF
cat >"${_fixdir}/ok.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# a comment mentioning nm -D lib.so | grep -q must not count
syms="$(nm -D /usr/local/lib/libfoo.so 2>/dev/null || true)"
find /usr/local/lib -name 'libfoo.so*' -print -quit | grep -q .
EOF
cat >"${_fixdir}/no-pipefail.sh" <<'EOF'
#!/usr/bin/env bash
ldd /usr/bin/true | grep -q libc && echo linked
EOF

t_case "lint self-test: flags the synthetic offender, and ONLY it"
_selftest_hits="$(_scan_pipefail_grepq "${_fixdir}")"
t_assert_contains "${_selftest_hits}" "bad.sh:3:" "the real anti-pattern must be caught"
t_assert_eq "1" "$(printf '%s\n' "${_selftest_hits}" | grep -c .)" \
  "comments, capture-then-case, bounded find, and no-pipefail files must not be flagged"

t_case "no unbounded nm/objdump/ldd | grep -q under pipefail in linux/scripts"
# Grandfathered substrings of "file:line:code"; never grow it, fix new sites with capture-then-case.
KNOWN_OFFENDERS=()
_hits="$(_scan_pipefail_grepq "${SCRIPTS_DIR}")"
for _k in ${KNOWN_OFFENDERS[@]+"${KNOWN_OFFENDERS[@]}"}; do
  _hits="$(printf '%s\n' "${_hits}" | grep -vF "${_k}" || true)"
done
[ -z "${_hits//[[:space:]]/}" ] && _hits=""
t_assert_eq "" "${_hits}" \
  "found unbounded producer | grep -q under pipefail (capture to a var, then match with case — see smoke-media.sh ~97-130)"

t_summary
