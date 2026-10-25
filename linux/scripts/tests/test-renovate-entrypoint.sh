#!/usr/bin/env bash
# Static adoption checks: removing a preset, wrapper, delegation or argv forwarding must turn the gate red; live lookups are outside this gate.
set -uo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"

CHECK="${TESTS_DIR}/../verify_renovate_entrypoint.py"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
REPO="${WORK}/consumer"
mkdir -p "${REPO}/.github/workflows" "${REPO}/scripts/linux"
git -C "${REPO}" init -q
printf '{"extends":["github>Kataglyphis/ANTfrastructure"]}\n' > "${REPO}/.github/renovate.json"
printf '#!/usr/bin/env bash\nexec bash "$ANTFRASTRUCTURE_DIR/linux/scripts/renovate-local.sh" "$@"\n' > "${REPO}/scripts/linux/renovate-local.sh"
printf 'on:\n  push:\njobs:\n  renovate:\n    uses: Kataglyphis/ANTfrastructure/.github/workflows/renovate-entrypoint.yml@develop\n' > "${REPO}/.github/workflows/renovate-entrypoint.yml"
git -C "${REPO}" add .github/renovate.json .github/workflows/renovate-entrypoint.yml scripts/linux/renovate-local.sh

run_check() {
  OUT="$(python3 "${CHECK}" "${REPO}" 2>&1)"
  RC=$?
}

t_case "a tracked shared-preset config and thin Bash wrapper pass"
run_check
t_assert_eq 0 "${RC}" "the consumer contract passes"
t_assert_contains "${OUT}" "Renovate entrypoint OK" "the result is visible"

t_case "a config without the shared preset fails"
printf '{"extends":["config:recommended"]}\n' > "${REPO}/.github/renovate.json"
run_check
t_assert_eq 1 "${RC}" "removing the preset turns the gate red"
t_assert_contains "${OUT}" "must extend" "the missing preset is named"
printf '{"extends":["github>Kataglyphis/ANTfrastructure"]}\n' > "${REPO}/.github/renovate.json"

t_case "an invalid config fails before claiming coverage"
printf '{\n' > "${REPO}/.github/renovate.json"
run_check
t_assert_eq 1 "${RC}" "bad JSON turns the gate red"
printf '{"extends":["github>Kataglyphis/ANTfrastructure"]}\n' > "${REPO}/.github/renovate.json"

t_case "a wrapper that drops argv fails"
printf '#!/usr/bin/env bash\nexec bash "$ANTFRASTRUCTURE_DIR/linux/scripts/renovate-local.sh"\n' > "${REPO}/scripts/linux/renovate-local.sh"
run_check
t_assert_eq 1 "${RC}" "dropping --apply turns the gate red"
t_assert_contains "${OUT}" '"$@"' "the missing forwarding is named"

t_case "a wrapper that bypasses the shared driver fails"
printf '#!/usr/bin/env bash\nexec bash local-copy.sh "$@"\n' > "${REPO}/scripts/linux/renovate-local.sh"
run_check
t_assert_eq 1 "${RC}" "a private copy turns the gate red"
t_assert_contains "${OUT}" "must delegate" "the missing hub call is named"

t_case "a commented-out hub reference cannot satisfy the live delegation probe"
printf '#!/usr/bin/env bash\n# linux/scripts/renovate-local.sh "$@"\nexec bash missing.sh "$@"\n' > "${REPO}/scripts/linux/renovate-local.sh"
run_check
t_assert_eq 1 "${RC}" "a dead delegate turns the gate red"
t_assert_contains "${OUT}" "--help failed" "the wrapper was actually invoked"

t_case "an argv array can forward options without spelling a literal positional expansion"
printf '#!/usr/bin/env bash\nFORWARD=("$@")\nexec bash "$ANTFRASTRUCTURE_DIR/linux/scripts/renovate-local.sh" "${FORWARD[@]}"\n' > "${REPO}/scripts/linux/renovate-local.sh"
run_check
t_assert_eq 0 "${RC}" "the existing array forwarding form remains accepted"

t_case "a missing CI caller is a failed adoption"
git -C "${REPO}" rm -qf --cached .github/workflows/renovate-entrypoint.yml
run_check
t_assert_eq 1 "${RC}" "CI coverage cannot vanish silently"
t_assert_contains "${OUT}" "renovate-entrypoint.yml is missing" "the missing caller is named"
git -C "${REPO}" add .github/workflows/renovate-entrypoint.yml

t_case "a commented workflow reference cannot satisfy the CI caller gate"
printf 'on:\n  push:\n# uses: Kataglyphis/ANTfrastructure/.github/workflows/renovate-entrypoint.yml@develop\n' > "${REPO}/.github/workflows/renovate-entrypoint.yml"
run_check
t_assert_eq 1 "${RC}" "a comment-only caller turns the gate red"
t_assert_contains "${OUT}" "must call" "the absent job call is named"
printf 'on:\n  push:\njobs:\n  renovate:\n    uses: Kataglyphis/ANTfrastructure/.github/workflows/renovate-entrypoint.yml@develop\n' > "${REPO}/.github/workflows/renovate-entrypoint.yml"

t_case "invalid Bash syntax fails"
printf '#!/usr/bin/env bash\nif then\n# linux/scripts/renovate-local.sh "$@"\n' > "${REPO}/scripts/linux/renovate-local.sh"
run_check
t_assert_eq 1 "${RC}" "syntax failure turns the gate red"
t_assert_contains "${OUT}" "invalid Bash syntax" "the parser's verdict is named"

t_case "an untracked wrapper fails"
git -C "${REPO}" rm -qf --cached scripts/linux/renovate-local.sh
run_check
t_assert_eq 1 "${RC}" "a wrapper absent from CI turns the gate red"
t_assert_contains "${OUT}" "exactly one tracked" "the missing tracked file is named"

t_summary
