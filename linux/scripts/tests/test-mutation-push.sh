#!/usr/bin/env bash
# Real pushes into a local bare remote through the real hook and gate: scope, Chrome delegation, coverage line, refusals. Does not start Chrome. See docs/code-quality-tooling.md#the-pre-push-hook
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
GATE="docs/scripts/verify_mutations.py"
REPO="${TESTS_DIR%/linux/scripts/tests}"
HOOKS="${REPO}/linux/host-config/git-hooks"
unset PREPUSH_MUTATION_JOBS GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX

_work="$(t_mktemp -d)"
_g() { git -C "${_work}/repo" -c user.name=t -c user.email=t@t -c core.hooksPath=/dev/null "$@"; }
_push() { git -C "${_work}/repo" -c core.hooksPath="${HOOKS}" push -q origin develop 2>&1; }
_tip() { git -C "${_work}/remote.git" rev-parse develop; }
_gate() { (cd "${_work}/repo" && python3 "${GATE}" "$@" 2>&1); }

_entry() {  # <id> <target> <find> <replace> <test>
  printf '{"id":"%s","target":"%s","find":"%s","replace":"%s","test":"%s","why":"probe"}' "$1" "$2" "$3" "$4" "$5"
}
_manifest() {  # <entry json...>
  local IFS=,
  printf '[%s]\n' "$*" > "${_work}/repo/docs/scripts/mutations.json"
}

# The marker is split so this suite is not classified as a Chrome suite itself.
_chrome_marker="t_skip_unless_""chrome"
_rig() {
  rm -rf "${_work}/repo" "${_work}/remote.git"
  git init -q --bare -b develop "${_work}/remote.git"
  git init -q -b develop "${_work}/repo"
  _g remote add origin "${_work}/remote.git"
  local r="${_work}/repo"
  mkdir -p "${r}/docs/scripts" "${r}/linux/scripts/tests"
  cp "${REPO}/docs/scripts/"{verify_mutations,mutation_parse,mutation_shards,mutation_push}.py "${r}/docs/scripts/"
  cp "${REPO}/linux/scripts/"{verify_comment_size,gate_scope,quality_allow}.py "${REPO}/linux/scripts/comment-size.allow" "${r}/linux/scripts/"
  echo 'exit 0' > "${r}/linux/scripts/tests/test-doc-numbers.sh"
  echo 'GUARD=on' > "${r}/plain.sh"
  echo 'GUARD=on' > "${r}/chrome.sh"
  echo 'GUARD=on' > "${r}/other.sh"
  echo 'grep -q GUARD=on plain.sh' > "${r}/plain-test.sh"
  # A suite that fails unmutated: a run of it would fail the gate, which is how these prove it never ran.
  printf '%s\nexit 1\n' "${_chrome_marker}" > "${r}/chrome-test.sh"
  echo 'exit 1' > "${r}/other-test.sh"
  _manifest "$(_entry probe.plain plain.sh GUARD=on GUARD=off 'bash plain-test.sh')" \
            "$(_entry probe.chrome chrome.sh GUARD=on GUARD=off 'bash chrome-test.sh')" \
            "$(_entry probe.other other.sh GUARD=on GUARD=off 'bash other-test.sh')"
  _g add -A
  _g commit -qm base
  _g push -q origin develop
}

t_case "a push proves what it changes and hands Chrome suites to CI, with the count"
_rig
echo '# edit' >> "${_work}/repo/plain.sh"
echo '# edit' >> "${_work}/repo/chrome.sh"
_g commit -qam change
_out="$(_push)"; _rc=$?
t_assert_eq "0" "${_rc}" "the push went through: ${_out}"
t_assert_eq "$(_g rev-parse HEAD)" "$(_tip)"
t_assert_contains "${_out}" "delegated 1 entr(ies) to CI, needs Chrome: bash chrome-test.sh"
t_assert_contains "${_out}" "coverage: proved 1 of 2 selected; 1 delegated to CI, 0 skipped by this host; the manifest holds 3"
t_assert_contains "${_out}" "bites   probe.plain"
t_assert_eq "0" "$(printf '%s\n' "${_out}" | grep -c -e ': the whole manifest' -e 'every recorded mutation is caught')" "a push scope never claims full coverage"
t_assert_contains "${_out}" "run-in-ci-image.sh" "the delegated proof can be run by hand"

t_case "without the flag the same Chrome suite runs: delegation is what kept it off the host"
t_assert_eq "1" "$(t_rc _gate --push-range HEAD~1...HEAD)"

t_case "a push that changes no recipe's files runs no suite, and says proved 0"
_rig
echo x > "${_work}/repo/notes.txt"
_g add -A
_g commit -qm notes
_out="$(_push)"; _rc=$?
t_assert_eq "0" "${_rc}" "${_out}"
t_assert_contains "${_out}" "nothing selected"

t_case "uncommitted edits are not push scope"
_rig
echo '# edit' >> "${_work}/repo/other.sh"
_g add other.sh
echo '# edit' >> "${_work}/repo/plain.sh"
t_assert_contains "$(_gate --push-range HEAD...HEAD)" "nothing selected" "neither staged nor edited files are in a committed range"
t_assert_contains "$(_gate --changed --base HEAD)" "FAIL" "--changed keeps its by-hand meaning, staged and edited included"
_g reset -q --hard

t_case "a recipe added or edited on old code is proved by the push that adds it"
_rig
_manifest "$(_entry probe.plain plain.sh GUARD=on GUARD=off 'bash plain-test.sh')" \
          "$(_entry probe.chrome chrome.sh GUARD=on GUARD=off 'bash chrome-test.sh')" \
          "$(_entry probe.other other.sh GUARD=on GUARD=off 'bash other-test.sh')" \
          "$(_entry probe.new plain.sh GUARD=on GUARD=gone 'bash plain-test.sh')"
_g commit -qam recipe
_out="$(_gate --push-range HEAD~1...HEAD)"
t_assert_contains "${_out}" "bites   probe.new"
t_assert_contains "${_out}" "proved 1 of 1 selected" "the three unchanged recipes stay out of scope"
_manifest "$(_entry probe.plain plain.sh GUARD=on GUARD=edited 'bash plain-test.sh')" \
          "$(_entry probe.chrome chrome.sh GUARD=on GUARD=off 'bash chrome-test.sh')" \
          "$(_entry probe.other other.sh GUARD=on GUARD=off 'bash other-test.sh')" \
          "$(_entry probe.new plain.sh GUARD=on GUARD=gone 'bash plain-test.sh')"
_g commit -qam edit
t_assert_contains "$(_gate --push-range HEAD~1...HEAD)" "bites   probe.plain" "an edited recipe is a changed recipe"

t_case "a surviving mutation stops the push and the remote stays put"
_rig
_before="$(_tip)"
echo 'exit 0' > "${_work}/repo/plain-test.sh"
_g commit -qam weaken
_out="$(_push)"; _rc=$?
t_assert_eq "1" "${_rc}"
t_assert_eq "${_before}" "$(_tip)"
t_assert_contains "${_out}" "SURVIVED"

t_case "the real comment-size gate stops a two-line comment the commit hook never saw"
_rig
_before="$(_tip)"
printf '# one\n# two\nGUARD=on\n' > "${_work}/repo/plain.sh"
_g commit -qam comment
_out="$(_push)"; _rc=$?
t_assert_eq "1" "${_rc}" "${_out}"
t_assert_eq "${_before}" "$(_tip)"
t_assert_contains "${_out}" "over one line"
t_assert_eq "0" "$(printf '%s\n' "${_out}" | grep -c 'bites')" "no mutation runs after it"

t_case "a remote that moved since the last fetch refuses before any proof"
_rig
git clone -q "${_work}/remote.git" "${_work}/other"
git -C "${_work}/other" -c user.name=t -c user.email=t@t commit -q --allow-empty -m parallel
git -C "${_work}/other" push -q origin develop
rm -rf "${_work}/other"
echo '# edit' >> "${_work}/repo/plain.sh"
_g commit -qam late
_out="$(_push)"; _rc=$?
t_assert_eq "1" "${_rc}"
t_assert_contains "${_out}" "refused before any proof"
t_assert_eq "0" "$(printf '%s\n' "${_out}" | grep -c 'bites')"

t_case "only a run that proved every entry may call itself whole, and CI's shards cannot delegate"
_rig
_manifest "$(_entry probe.plain plain.sh GUARD=on GUARD=off 'bash plain-test.sh')"
_g commit -qam one
_out="$(_gate)"
t_assert_contains "${_out}" "coverage: proved 1 of 1: the whole manifest"
t_assert_contains "${_out}" "every recorded mutation is caught"
_manifest "$(_entry probe.plain plain.sh GUARD=on GUARD=off 'bash plain-test.sh')" "$(_entry probe.two plain.sh GUARD=on GUARD=two 'bash plain-test.sh')"
_out="$(_gate --only probe.two)"
t_assert_contains "${_out}" "coverage: proved 1 of 1 selected; 0 delegated to CI, 0 skipped by this host; the manifest holds 2"
t_assert_contains "${_out}" "that is not the whole manifest"
_g commit -qam two
t_assert_eq "2" "$(t_rc _gate --delegate-chrome --shard 0/2)" "a shard that delegates would shrink the only full proof"
t_assert_eq "2" "$(t_rc _gate --push-range nosuchref...HEAD)" "a failed diff is not an empty push"
t_assert_eq "2" "$(t_rc _gate --push-range HEAD)" "a range without its two ends is refused"

t_case "the real tree: the Chrome suites are classified, and CI's calls do not delegate"
_chrome_suites="$(cd "${REPO}/docs/scripts" && python3 -c '
import json, mutation_push, sys
root = sys.argv[1]
cmds = {e["test"] for e in json.load(open("mutations.json"))}
print(" ".join(sorted(c.rsplit("/", 1)[-1] for c in cmds if mutation_push.needs_chrome(c, root))))' "${REPO}")"
t_assert_eq "test-check-live-site.sh test-docs-sidebars.sh test-webgpu-canvas-readback.sh" "${_chrome_suites}"
for _f in linux/scripts/preflight.sh .github/workflows/linux-x64.yml .github/workflows/mutation-gates.yml; do
  t_assert_eq "0" "$(grep -c -e '--delegate-chrome' -e '--push-range' "${REPO}/${_f}")" "${_f} proves every entry"
done

t_summary
