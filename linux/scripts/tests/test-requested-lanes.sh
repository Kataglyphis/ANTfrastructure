#!/usr/bin/env bash
# Tests for the requested-lanes action's script: which [ci <word>] tokens pick which lanes.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${TESTS_DIR}/../../../.github/actions/requested-lanes/requested-lanes.sh"
source "${TESTS_DIR}/test-harness.sh"

LANES_ALL="linux-arm64 windows-x64 windows-arm64 android web"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

# pick <request> <commit message>...: the lanes= value the script writes for a push of those commits.
pick() {
  local request="$1"; shift
  printf '%s\n' "$@" | jq -R . | jq -s '{commits: map({message: .}), head_commit: {message: (.[-1] // "")}}' > "${work}/event.json"
  : > "${work}/out"
  GITHUB_EVENT_PATH="${work}/event.json" GITHUB_OUTPUT="${work}/out" LANES="${LANES_ALL}" REQUEST="${request}" \
    bash "${SCRIPT}" > "${work}/log" 2>&1
  sed -n 's/^lanes=//p' "${work}/out"
}

t_case "a push without a token picks nothing"
t_assert_eq " " "$(pick "" "fix(web): a typo")"

t_case "an OS picks every lane of that OS"
t_assert_eq " windows-x64 windows-arm64 " "$(pick "" "feat: x [ci windows]")"

t_case "an architecture picks every lane of that architecture"
t_assert_eq " linux-arm64 windows-arm64 " "$(pick "" "feat: x [ci arm64]")"

t_case "a full lane name picks that lane alone"
t_assert_eq " windows-arm64 " "$(pick "" "feat: x [ci windows-arm64]")"

t_case "all picks every lane"
t_assert_eq " ${LANES_ALL} " "$(pick "" "chore(release): 2.1.0 [ci all]")"

t_case "one token may name several words"
t_assert_eq " windows-x64 windows-arm64 android " "$(pick "" "feat: x [ci windows android]")"

t_case "a token in an earlier commit of the push counts"
t_assert_eq " web " "$(pick "" "feat: one [ci web]" "fix: two" "docs: three")"

t_case "tokens are not case-sensitive"
t_assert_eq " web " "$(pick "" "feat: x [CI Web]")"

t_case "a part of a word is not a lane"
t_assert_eq " " "$(pick "" "feat: x [ci arm]")"
t_assert_contains "$(cat "${work}/log")" "::warning::[ci arm] names no lane here"

t_case "only the [ci <word>] form counts"
t_assert_eq " " "$(pick "" "feat: x [ci-windows] (ci windows) ci windows")"

t_case "a dispatch's request picks lanes without any commit"
t_assert_eq " android web " "$(pick "android, web")"

t_case "a request is reduced to lane-name characters"
t_assert_eq " web " "$(pick 'web; $(touch '"${work}"'/pwned)')"
t_assert_fails test -e "${work}/pwned"

t_summary
