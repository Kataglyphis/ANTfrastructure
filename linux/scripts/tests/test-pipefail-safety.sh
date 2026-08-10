#!/usr/bin/env bash
# Guards against the pipefail-SIGPIPE false-failure bug class (backlog T2).
#
# Under `set -o pipefail`, `producer | grep -q MATCH` is a trap whenever the
# producer emits more than one pipe buffer: grep -q exits at the FIRST match
# and closes the pipe, the still-writing producer takes SIGPIPE (exit 141),
# and pipefail reports the whole PIPELINE as failed — so the SUCCESS direction
# (symbol present) fails while the failure direction (no match; grep drains
# everything, producer exits 0) looks fine. Empirically hit 2026-08-10:
# smoke-media.sh reported libtensorflowlite_c.so as a stub although nm showed
# TfLiteInterpreterCreate exported — fixed in 7ca9e4b by capture-then-case
# (see 06-packaging/smoke-media.sh ~lines 97-130).
#
# This suite (1) proves both directions of the failure mode deterministically
# and (2) lints the script tree so unbounded-producer `| grep -q` sites under
# pipefail cannot quietly return.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${TESTS_DIR}/.." && pwd)"
source "${TESTS_DIR}/test-harness.sh"

# ---------------------------------------------------------------------------
# Part 1 — behavioral proof. seq 300000 emits ~2 MB, far beyond any Linux pipe
# capacity (64K default, 1M fcntl max), so the producer is GUARANTEED to still
# be writing when grep -q exits early — no timing race, the outcome is
# deterministic in both directions.

t_case "pipefail + EARLY match: pipeline reports 141 (producer took SIGPIPE)"
bash -c 'set -o pipefail; seq 300000 | grep -q "^1$"'; rc=$?
t_assert_eq "141" "${rc}" \
  "a FOUND symbol must reproduce the false-failure (grep quits, seq gets SIGPIPE)"

t_case "same early match WITHOUT pipefail: 0 — pipefail is the trigger"
bash -c 'seq 300000 | grep -q "^1$"'; rc=$?
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

# ---------------------------------------------------------------------------
# Part 2 — tree lint. Pragmatic heuristic: the producers that bit us (and are
# structurally unbounded on real libraries) are the ELF inspectors nm/objdump/
# ldd. Bounded producers — `find ... -print -quit | grep -q .` (emits at most
# one line), `echo`/`printf` of a variable, `head -1` — cannot outlive grep by
# a pipe buffer and are NOT flagged.

# Emits "file:line:code" for every suspicious site under $1. Skips:
#   - files that never set pipefail (the bug needs it),
#   - the tests/ dir (this suite deliberately contains the anti-pattern),
#   - comment lines,
#   - lines carrying `-print -quit` (the bounded find idiom).
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

# Self-test first: a lint that silently matches nothing is worse than no lint
# (see the toothless-verify-runtime-paths backlog entry).
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
# Known offenders (documented grandfather list, DO NOT grow it — fix new sites
# with capture-then-case instead). Entries are substrings matched against the
# "file:line:code" hit, e.g. "06-packaging/foo.sh:" or a code fragment.
# Currently EMPTY: the only real site (smoke-media.sh LiteRT nm check) was
# already fixed in 7ca9e4b before this suite landed.
KNOWN_OFFENDERS=()
_hits="$(_scan_pipefail_grepq "${SCRIPTS_DIR}")"
for _k in ${KNOWN_OFFENDERS[@]+"${KNOWN_OFFENDERS[@]}"}; do
  _hits="$(printf '%s\n' "${_hits}" | grep -vF "${_k}" || true)"
done
[ -z "${_hits//[[:space:]]/}" ] && _hits=""
t_assert_eq "" "${_hits}" \
  "found unbounded producer | grep -q under pipefail (capture to a var, then match with case — see smoke-media.sh ~97-130)"

t_summary
