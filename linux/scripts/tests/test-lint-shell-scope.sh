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

t_case "the deleted .githooks copy is really gone"
t_assert_fails test -e "${TESTS_DIR}/../../../.githooks/pre-commit"

t_summary
