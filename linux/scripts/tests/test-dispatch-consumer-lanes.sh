#!/usr/bin/env bash
# dispatch-consumer-lanes.sh against a fake gh that records its calls; no real dispatch, no consumer's own workflow.
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${here}/test-harness.sh"
tool="${here}/../dispatch-consumer-lanes.sh"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

# The fake gh records each call and refuses the one that names FAKE_GH_REFUSE.
fake_gh="${work}/bin/gh"
mkdir -p "${fake_gh%/*}"
t_write_exec_stub "${fake_gh}"
printf '%s\n' 'printf "%s\n" "$*" >> "${FAKE_GH_CALLS}"' \
  'case "$*" in *"${FAKE_GH_REFUSE:-no such repo}"*) exit 1 ;; esac' >> "${fake_gh}"
printf '%s' '{"schema_version": 1, "owner": "Org", "ref": "develop", "consumers": ["One", "Two"], "tags": {' \
  '"latest": {"lanes": "linux android web", "linux_x64": true}, ' \
  '"winamd64": {"lanes": "windows", "linux_x64": false}}}' > "${work}/plan.json"

# run <args...>: the tool with the fake gh and the fixture plan; output in ${work}/out, status in ${work}/rc.
run() {
  : > "${work}/calls"
  PATH="${work}/bin:${PATH}" FAKE_GH_CALLS="${work}/calls" CONSUMER_LANES_CONFIG="${work}/plan.json" \
    bash "${tool}" "$@" > "${work}/out" 2>&1
  printf '%s' "$?" > "${work}/rc"
}

run --tag latest
t_case "a Linux publish runs each consumer's on-request Linux, Android and web lanes and its x64 lane"
t_assert_grep "${work}/rc" '^0$'
t_assert_eq 4 "$(wc -l < "${work}/calls" | tr -d ' ')" "two consumers, two workflows each"
t_assert_grep "${work}/calls" '^workflow run on-request.yml -R Org/One --ref develop -f lanes=linux android web$'
t_assert_grep "${work}/calls" '^workflow run linux-x64.yml -R Org/Two --ref develop$'

run --tag winamd64
t_case "a Windows publish runs the Windows lanes only"
t_assert_eq 2 "$(wc -l < "${work}/calls" | tr -d ' ')" "one dispatch per consumer"
t_assert_no_grep "${work}/calls" 'linux-x64.yml'
t_assert_grep "${work}/calls" '^workflow run on-request.yml -R Org/Two --ref develop -f lanes=windows$'

run --tag candidate-123
t_case "a tag without declared lanes dispatches nothing and is no error"
t_assert_grep "${work}/rc" '^0$'
t_assert_eq 0 "$(wc -l < "${work}/calls" | tr -d ' ')" "no gh call"
t_assert_grep "${work}/out" 'no consumer lanes are declared for :candidate-123'

FAKE_GH_REFUSE='Org/Two' run --tag winamd64
t_case "a refused dispatch fails the step, names its command, and the others are still sent"
t_assert_grep "${work}/rc" '^1$'
t_assert_grep "${work}/out" '^FAILED to dispatch; run by hand: gh workflow run on-request.yml -R Org/Two --ref develop -f lanes=windows$'
t_assert_grep "${work}/out" '^dispatched Org/One on-request.yml \(windows\)$'

run --tag latest --dry-run
t_case "a dry run sends nothing and prints every command"
t_assert_eq 0 "$(wc -l < "${work}/calls" | tr -d ' ')" "no gh call"
t_assert_eq 4 "$(grep -c '^would run: gh workflow run' "${work}/out")" "four commands"

run
t_case "without --tag it refuses"
t_assert_grep "${work}/rc" '^2$'

t_case "the real plan names every consumer that has an on-request lane, and each published tag"
real="${here}/../../../shared/config/image-consumer-lanes.json"
t_assert_eq "AccelerANTgine BeschleunigerBallett OmniAccelerANT OrchestrANT OxidANT WebDavClient" \
  "$(python3 -c 'import json, sys; print(" ".join(json.load(open(sys.argv[1]))["consumers"]))' "${real}")" "consumers"
t_assert_eq "latest latest-nvidia latest-rocm winamd64 winamd64-nvidia winamd64-rocm winarm64" \
  "$(python3 -c 'import json, sys; print(" ".join(sorted(json.load(open(sys.argv[1]))["tags"])))' "${real}")" "tags"

t_summary
