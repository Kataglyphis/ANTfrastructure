#!/usr/bin/env bash
# Local Git remotes prove the pin helper stages only the requested gitlink and rejects stale or dirty inputs.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
source "${TESTS_DIR}/git-fixture-env.sh"
REPO="$(cd "${TESTS_DIR}/../../.." && pwd)"
PIN="${REPO}/linux/scripts/pin-antfrastructure-submodule.py"
PY="${PREFLIGHT_PYTHON:-python3}"
mkdir -p "${REPO}/logs/test-results"
work="$(mktemp -d "${REPO}/logs/test-results/pin-antfrastructure.XXXXXX")" || exit 1
trap 'rm -rf -- "${work}"' EXIT

hub_remote="${work}/ANTfrastructure.git"
hub_seed="${work}/hub-seed"
consumer_remote="${work}/consumer.git"
consumer_seed="${work}/consumer-seed"
consumer="${work}/consumer"
git init -q --bare -b develop "${hub_remote}"
git init -q -b develop "${hub_seed}"
printf 'old\n' > "${hub_seed}/tool.txt"
t_git_commit "${hub_seed}"
old="$(git -C "${hub_seed}" rev-parse HEAD)"
git -C "${hub_seed}" remote add origin "${hub_remote}"
git -C "${hub_seed}" push -q origin develop

git init -q --bare -b main "${consumer_remote}"
git init -q -b main "${consumer_seed}"
git -C "${consumer_seed}" commit -q --allow-empty -m init
git -C "${consumer_seed}" submodule add -q -b develop "${hub_remote}" third_party/ANTfrastructure
t_git_commit "${consumer_seed}"
git -C "${consumer_seed}" remote add origin "${consumer_remote}"
git -C "${consumer_seed}" push -q origin main
git clone -q --recurse-submodules "${consumer_remote}" "${consumer}"

printf 'new\n' > "${hub_seed}/tool.txt"
t_git_commit "${hub_seed}"
fresh="$(git -C "${hub_seed}" rev-parse HEAD)"
git -C "${hub_seed}" push -q origin develop
printf 'other staged work\n' > "${consumer}/other.txt"
git -C "${consumer}" add -- other.txt
before="$(git -C "${consumer}" rev-parse HEAD)"

_pin() { "${PY}" "${PIN}" --repo "${consumer}" --branch main --sha "$1"; }
_staged_pin() { git -C "${consumer}" ls-files --stage -- third_party/ANTfrastructure; }

t_case "the explicit remote tip is checked out and only its gitlink is staged"
t_assert_contains "$(t_out _pin "${fresh}")" "PINNED consumer:"
t_assert_eq "${fresh}" "$(git -C "${consumer}/third_party/ANTfrastructure" rev-parse HEAD)"
t_assert_eq "160000 ${fresh} 0" "$(printf '%s\n' "$(_staged_pin)" | cut -f1)"
t_assert_eq "${before}" "$(git -C "${consumer}" rev-parse HEAD)" "the helper must not commit"
t_assert_eq "${before}" "$(git -C "${consumer_remote}" rev-parse main)" "the helper must not push"
t_assert_contains "$(git -C "${consumer}" diff --cached --name-only)" "other.txt" "existing staged work survives"

t_case "a stale SHA and a wrong consumer branch cannot alter the staged pin"
t_assert_eq 2 "$(t_rc _pin "${old}")"
t_assert_eq "160000 ${fresh} 0" "$(printf '%s\n' "$(_staged_pin)" | cut -f1)"
t_assert_eq 2 "$(t_rc "${PY}" "${PIN}" --repo "${consumer}" --branch develop --sha "${fresh}")"
t_assert_eq 2 "$(t_rc "${PY}" "${PIN}" --repo "${consumer}" --branch main --sha short)"

_reject_stale() {
  local driver="$1" rc=0
  "${PY}" "${driver}" --repo "${consumer}" --branch main --sha "${old}" >/dev/null 2>&1 || rc=$?
  [ "${rc}" -eq 2 ] || return 1
  if [ "$(printf '%s\n' "$(_staged_pin)" | cut -f1)" != "160000 ${fresh} 0" ]; then
    return 1
  fi
  return 0
}
t_case "removing remote-tip validation makes the stale-pin control fail"
t_assert_ok _reject_stale "${PIN}"
sed 's/if git(sub, "rev-parse", "FETCH_HEAD") != sha:/if False:/' "${PIN}" > "${work}/unsafe-pin.py"
t_assert_fails _reject_stale "${work}/unsafe-pin.py"
t_assert_eq 0 "$(t_rc _pin "${fresh}")" "the legitimate pin restores the fixture after the mutant"

t_case "a dirty or uninitialized hub checkout is refused"
printf 'dirty\n' >> "${consumer}/third_party/ANTfrastructure/tool.txt"
t_assert_eq 2 "$(t_rc _pin "${fresh}")"
git -C "${consumer}/third_party/ANTfrastructure" checkout -q -- tool.txt
git -C "${consumer}" submodule deinit -q -f -- third_party/ANTfrastructure
t_assert_eq 2 "$(t_rc _pin "${fresh}")"

t_summary
