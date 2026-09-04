#!/usr/bin/env bash
# lint-shell.sh admits EXTENSION-LESS files that carry a shell shebang. That rule
# is load-bearing: the commit hook (linux/host-config/git-hooks/pre-commit) is a
# git hook, so it cannot have a .sh suffix, and without the rule it is linted by
# nothing. YC proposed removing it as "only there for the deleted .githooks copy"
# — this suite exists so nobody acts on that.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SUBJECT="${TESTS_DIR}/../lint-shell.sh"
LIVE_HOOK="${TESTS_DIR}/../../host-config/git-hooks/pre-commit"

_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT

t_case "the live commit hook exists and is extension-less — the reason the rule is needed"
t_assert_ok test -f "${LIVE_HOOK}"
t_case "its basename carries no dot"
t_assert_fails grep -q -F -e '.' <<<"$(basename "${LIVE_HOOK}")"

t_case "lint-shell.sh checks the live hook when handed it explicitly"
t_assert_contains "$(bash "${SUBJECT}" "${LIVE_HOOK}" 2>&1)" "1 file(s)"

t_case "an extension-less file WITHOUT a shell shebang is not swept in"
printf 'Just prose, not a script.\n' > "${_work}/READMEISH"
t_assert_contains "$(bash "${SUBJECT}" "${_work}/READMEISH" 2>&1)" "no shell scripts to check"

t_case "an extension-less file WITH a shell shebang is checked"
printf '#!/usr/bin/env bash\ntrue\n' > "${_work}/hookish"
t_assert_contains "$(bash "${SUBJECT}" "${_work}/hookish" 2>&1)" "1 file(s)"

t_case "a file with some OTHER extension is not swept in"
printf '#!/usr/bin/env bash\ntrue\n' > "${_work}/thing.md"
t_assert_contains "$(bash "${SUBJECT}" "${_work}/thing.md" 2>&1)" "no shell scripts to check"

t_case "the rule is marked load-bearing where it lives, so the reason survives edits"
t_assert_contains "$(cat "${SUBJECT}")" "LOAD-BEARING"

t_case "the hook resolves shellcheck through lint-shell.sh, its one owner"
t_assert_contains "$(cat "${LIVE_HOOK}")" 'lint-shell.sh --print-bin'

t_case "the hook never invokes a bare PATH shellcheck"
t_assert_fails grep -q -E -e '^[[:space:]]*shellcheck ' "${LIVE_HOOK}"

t_case "--print-bin prints an executable, so the hook's resolution cannot be vacuous"
t_assert_ok test -x "$(bash "${SUBJECT}" --print-bin)"

# docs/cross-build-verification.md quotes two hook line spans as `:NN-MM`. They
# are re-derived here from the hook itself, so an edit that moves either block
# fails the suite instead of rotting the prose.
DOC="${TESTS_DIR}/../../../docs/cross-build-verification.md"
# _span <first-line-regex> <awk-body-picking-the-last-line>
_span() {
  local a b
  a="$(grep -n -E -e "$1" "${LIVE_HOOK}" | head -1 | cut -d: -f1)"
  b="$(awk -v s="${a}" "$2" "${LIVE_HOOK}")"
  printf ':%s-%s' "${a}" "${b}"
}
_slugs_span()  { _span '^_FAST_SLUGS=' 'NR>=s && !/\\$/ { print NR; exit }'; }
_staged_span() { _span '^_staged_sh='  'NR>s && /^fi$/ { print NR; exit }'; }

t_case "the doc's _FAST_SLUGS offset is the span the hook actually has"
t_assert_contains "$(cat "${DOC}")" "(\`$(_slugs_span)\`)"

t_case "the doc's staged-shell-block offset is the span the hook actually has"
t_assert_contains "$(cat "${DOC}")" "(\`$(_staged_span)\`,"

t_case "both derivations found a real span, so neither assertion can pass on empty"
t_assert_fails test "$(_slugs_span)" = ":-"
t_assert_fails test "$(_staged_span)" = ":-"

t_case "the DEFAULT sweep contains the hook, so the warning ratchet watches it too"
t_assert_contains "$(bash "${SUBJECT}" --list-files)" "linux/host-config/git-hooks/pre-commit"
t_assert_fails grep -q -F -e "outside the lint-shell.sh scope" <<<"$(
  "${PREFLIGHT_PYTHON:-python3}" "${TESTS_DIR}/../verify_shellcheck_warnings.py" \
    --files "${LIVE_HOOK}" 2>&1)"

t_case "the deleted .githooks copy is really gone"
t_assert_fails test -e "${TESTS_DIR}/../../../.githooks/pre-commit"

t_summary
