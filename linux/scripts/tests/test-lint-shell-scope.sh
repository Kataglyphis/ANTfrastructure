#!/usr/bin/env bash
# lint-shell.sh must admit extension-less shell-shebang files: the commit hook cannot carry a .sh suffix.
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

# The doc's two `:NN-MM` hook spans are re-derived here, so moving either block fails instead of rotting.
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

# --root: inside a consumer the default root is the hub; the broken fixture is an error-level `if` without `fi`.
_broken_sh() { printf '#!/usr/bin/env bash\nif [ 1 = 1 ] ; then\n  echo hi\n' > "$1"; }
_plant() {  # <dir> <shape>
  case "$2" in
    broken|vendored) _broken_sh "$1/${2}.sh" ;;
    clean)           printf '#!/usr/bin/env bash\necho hi\n' > "$1/clean.sh" ;;
    empty)           printf 'no shell here\n' > "$1/README.md" ;;
  esac
}
# _consumer <clean|broken|empty> [vendored] -> a consumer checkout.
_consumer() { t_consumer_fixture "${_work}" _plant "$@"; }

t_case "--root decides WHICH tree is graded, and the verdicts follow the argument"
_c_clean="$(_consumer clean)"
_c_broken="$(_consumer broken)"
t_assert_eq "0" "$(t_rc bash "${SUBJECT}" --root "${_c_clean}")" \
  "the gate must be able to be green over a consumer, or the red below proves only that it is broken"
t_assert_eq "1" "$(t_rc bash "${SUBJECT}" --root "${_c_broken}")" \
  "a gate that ignored --root would grade ANTfrastructure and give both checkouts the same verdict"
t_assert_contains "$(bash "${SUBJECT}" --root "${_c_broken}" 2>&1)" "broken.sh" \
  "the finding has to name the consumer's file to be actionable"

t_case "--root=<dir> is the same argument"
t_assert_eq "1" "$(t_rc bash "${SUBJECT}" --root="${_c_broken}")"

t_case "the consumer's scope is the CONSUMER's files, not this repo's"
_scope="$(bash "${SUBJECT}" --root "${_c_clean}" --list-files)"
t_assert_eq "clean.sh" "${_scope}"
t_assert_fails grep -q -F -e 'linux/scripts/lint-shell.sh' <<<"${_scope}"

t_case "a vendored checkout inside the consumer is a gitlink, and is not graded"
_c_vendored="$(_consumer clean vendored)"
t_assert_fails grep -q -F -e 'vendored.sh' \
  <<<"$(bash "${SUBJECT}" --root "${_c_vendored}" --list-files)"
t_assert_eq "0" "$(t_rc bash "${SUBJECT}" --root "${_c_vendored}")" \
  "grading the vendored hub AS the consumer is the same wrong-tree bug from the other direction"
t_assert_eq "1" "$(t_rc bash "${SUBJECT}" "${_c_vendored}/${T_VENDORED}/vendored.sh")" \
  "and the vendored script really is broken, so the green above is about scope, not about a clean file"

t_case "an empty file list under an explicit root is an ERROR, never 'no shell scripts to check'"
_c_empty="$(_consumer empty)"
_out="$(bash "${SUBJECT}" --root "${_c_empty}" 2>&1)"
t_assert_eq "1" "$(t_rc bash "${SUBJECT}" --root "${_c_empty}")" \
  "this gate skips paths it cannot find, so a scope built from a wrong prefix arrives here empty and used to pass"
t_assert_contains "${_out}" "a root was given explicitly"
t_assert_fails grep -q -F -e 'no shell scripts to check' <<<"${_out}"

t_case "a named file that does not exist under the root is an ERROR, not a silent skip"
t_assert_eq "1" "$(t_rc bash "${SUBJECT}" --root "${_c_clean}" no-such.sh)"

t_case "a root that is not a git checkout refuses instead of guessing a scope"
_c_nogit="$(mktemp -d "${_work}/nogit.XXXXXX")"
printf '#!/usr/bin/env bash\necho hi\n' > "${_c_nogit}/app.sh"
t_assert_eq "1" "$(t_rc bash "${SUBJECT}" --root "${_c_nogit}")"
t_assert_contains "$(bash "${SUBJECT}" --root "${_c_nogit}" 2>&1)" "is not a git checkout" \
  "a scope silently read out of a non-checkout is a scope nobody chose"

t_case "a root that does not exist refuses, it does not fall back to this repo"
t_assert_eq "1" "$(t_rc bash "${SUBJECT}" --root "${_work}/no-such-checkout")" \
  "falling back would grade a clean tree and report OK for a checkout nobody looked at"
# The message too: a fallback failing later for another reason still hides which tree was asked for.
t_assert_contains "$(bash "${SUBJECT}" --root "${_work}/no-such-checkout" 2>&1)" \
  "lint root not found"

t_case "--root with no value is a usage error, not a silent default"
t_assert_eq "1" "$(t_rc bash "${SUBJECT}" --root)"

t_case "the default scope is untouched by all of the above"
t_assert_contains "$(bash "${SUBJECT}" --list-files)" "linux/host-config/git-hooks/pre-commit"

t_summary
