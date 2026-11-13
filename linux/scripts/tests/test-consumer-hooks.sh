#!/usr/bin/env bash
# The consumer hook pair under real git commits and pushes, over a hub copy whose downloaded linters are stubs; not covered: shellcheck, actionlint, gitleaks and ruff themselves. See docs/adopting-in-a-new-project.md#the-git-hooks-by-reference
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
source "${TESTS_DIR}/gate-tree.sh"
t_private_tmpdir
HUB="${TESTS_DIR%/linux/scripts/tests}"
HOOKS_REL=third_party/ANTfrastructure/shared/linux/templates/git-hooks
# A hook or a CI runner that starts this suite must not hand its own git or CI state to the fixtures.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX CI
# Sourced for the gate lists and the notice function; the hooks run the copy inside each fixture.
# shellcheck source=../run-lint-gates.sh
source "${HUB}/linux/scripts/run-lint-gates.sh"

_work="$(t_mktemp -d)"
# A developer's global core.hooksPath or signing key must not decide what a fixture's git does.
: > "${_work}/gitconfig"
export GIT_CONFIG_GLOBAL="${_work}/gitconfig" GIT_CONFIG_NOSYSTEM=1
# Every stub appends here: a shell stub its name, a Python stub its arguments.
export HOOK_TEST_ARGV="${_work}/calls.log" HOOK_TEST_GATE_RC=0 HOOK_TEST_STALE_RC=0
_REAL=(shared/linux/templates/git-hooks/pre-commit shared/linux/templates/git-hooks/pre-push
  linux/scripts/run-lint-gates.sh linux/scripts/01-core/gates.sh linux/scripts/01-core/python-probe.sh
  linux/scripts/gate_scope.py linux/scripts/quality_allow.py linux/scripts/verify_large_files.py
  docs/scripts/verify_mutations.py docs/scripts/mutation_parse.py docs/scripts/mutation_shards.py
  docs/scripts/mutation_push.py)
# Short of a real token's length, so the hub's own secret scan does not read this suite as a leak.
_TOKEN="ghp_fixture"

# <path>: a green shell gate that records its name.
_stub_sh() {
  mkdir -p "$(dirname "$1")"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "${0##*/}" >> "${HOOK_TEST_ARGV}"\n' > "$1"
}

# <path>: gitleaks' stand-in, reporting a file that holds the canary's prefix the way the self-test reads a finding.
_stub_secrets() {
  cat > "$1" <<'STUB'
#!/usr/bin/env bash
printf 'lint-secrets.sh %s\n' "$1" >> "${HOOK_TEST_ARGV}"
if [ -f "$1" ]; then dir="$(dirname "$1")"; src="$(basename "$1")"; else dir="$1"; src=.; fi
cd "${dir}" || exit 2
hits="$(grep -rl -e 'ghp_' "${src}" 2>/dev/null | sed 's|^\./||' || true)"
if [ -n "${hits}" ]; then
  printf '%s\n' "${hits}" | sed 's/$/:github-pat:1/'
  exit 1
fi
echo "secret scan: clean"
STUB
}

# <dir>: the real hooks, aggregator and offline gates, their modes kept; a gate that needs a downloaded linter is a stub.
_hub_copy() {
  local d="$1" rel
  for rel in "${_REAL[@]}"; do
    mkdir -p "${d}/$(dirname "${rel}")"
    cp -p "${HUB}/${rel}" "${d}/${rel}"
  done
  for rel in lint-shell.sh lint-workflows.sh lint-python.sh; do _stub_sh "${d}/linux/scripts/${rel}"; done
  _stub_sh "${d}/shared/config/sync-shared-config.sh"
  _stub_secrets "${d}/linux/scripts/lint-secrets.sh"
  for rel in docs/scripts/sync_versions.py docs/scripts/verify_doc_dupes.py linux/scripts/verify_readme_length.py \
    "${_LINT_GATES_RATCHET_DOC_GATES[@]}" "${_LINT_GATES_RATCHET_GATES[@]/%/.py}"; do
    case "${rel}" in */*) ;; *) rel="linux/scripts/${rel}" ;; esac
    [ -f "${d}/${rel}" ] || gate_stub_recorder "${d}/${rel}"
  done
}

_tip() { git -C "$1.git" rev-parse develop; }
# <dir> <git args...>: one git command over a fresh call log; output in _out, status in _rc.
_run() {
  : > "${HOOK_TEST_ARGV}"
  _out="$(git -C "$@" 2>&1)"
  _rc=$?
}

# [bare]: a consumer with the hub copy inside, one pushed commit and the adoption page's config line; bare has no wrapper.
_consumer() {
  local d
  d="$(mktemp -d "${_work}/consumer.XXXXXX")"
  {
    git init -q -b develop "${d}"
    git init -q --bare -b develop "${d}.git"
    git -C "${d}" config user.name fixture
    git -C "${d}" config user.email fixture@example.invalid
    git -C "${d}" remote add origin "${d}.git"
    mkdir -p "${d}/third_party" "${d}/scripts/linux/tests"
    cp -Rp "${_work}/hub" "${d}/third_party/ANTfrastructure"
    printf 'third_party/\n' >> "${d}/.git/info/exclude"
    printf '# fixture\n' > "${d}/README.md"
    printf 'antfrastructure-sh\n' > "${d}/.antfrastructure-shared.manifest"
    printf 'GUARD=on\n' > "${d}/scripts/linux/subject.sh"
    printf '[{"id":"demo.guard","target":"scripts/linux/subject.sh","find":"GUARD=on","replace":"GUARD=off","test":"true","why":"fixture"}]\n' \
      > "${d}/scripts/linux/tests/demo-mutations.json"
    if [ "${1:-}" != bare ]; then
      cat > "${d}/scripts/linux/run-lint-gates.sh" <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
exec bash "${root}/third_party/ANTfrastructure/linux/scripts/run-lint-gates.sh" "${root}" --ratchets "$@"
WRAPPER
    fi
    git -C "${d}" add -A
    git -C "${d}" commit -qm base
    git -C "${d}" push -q origin develop
    git -C "${d}" config core.hooksPath "${HOOKS_REL}"
  } >/dev/null 2>&1
  printf '%s' "${d}"
}

# <dir> <file> <text>: stage a file with that content.
_stage() {
  mkdir -p "$(dirname "$1/$2")"
  printf '%s\n' "$3" > "$1/$2"
  git -C "$1" add -f "$2"
}

# <dir> <want rc> [<file> <text>]: commit what is staged, and that file, past the commit hook; push; hold the push hook's verdict.
_push() {
  [ "$#" -lt 4 ] || _stage "$1" "$3" "$4"
  git -C "$1" commit -q --no-verify -m change >/dev/null 2>&1
  _run "$1" push -q origin develop
  t_assert_eq "$2" "${_rc}" "${_out}"
}

# <dir> <marker>: stage an extension that records where and how it ran, then exits EXTENSION_RC.
_extension() {
  cat > "$1/scripts/linux/pre-push-checks.sh" <<EXTENSION
{ pwd; echo "prefix=\${GIT_PREFIX+set}"; echo "calls=\$(grep -c . "\${HOOK_TEST_ARGV}")"; echo "stdin=\$(cat)"; } > '$2'
exit "\${EXTENSION_RC:-0}"
EXTENSION
  git -C "$1" add scripts/linux/pre-push-checks.sh
}

_section_commit() {
  local d bare head

  t_case "the adoption page's config line runs the hook, and a clean commit passes on the staged checks alone"
  d="$(_consumer)"
  _stage "${d}" README.md "more"
  SECONDS=0
  _run "${d}" commit -q -m clean
  t_assert_eq 0 "${_rc}" "${_out}"
  t_assert_contains "${_out}" "pre-commit: scripts/linux/run-lint-gates.sh --staged" "the repo's own wrapper carries its flags"
  t_assert_contains "${_out}" "STAGED CHECKS OK (2 gate(s))" "large files, behind the wrapper's --ratchets, and the secret scan"
  t_assert_grep "${HOOK_TEST_ARGV}" '^lint-secrets\.sh .*/tree/README\.md$'
  t_assert_no_grep "${HOOK_TEST_ARGV}" '^(lint-(shell|workflows|python)|sync-shared-config)\.sh$|^--'
  t_assert_eq 1 "$((SECONDS < 60))" "a commit hook that takes a minute teaches --no-verify; took ${SECONDS}s"

  t_case "a staged 1 MB binary stops the commit, and the freeze file of the ratchet lets it through"
  head -c 1048576 /dev/zero > "${d}/blob.bin"
  git -C "${d}" add blob.bin
  head="$(git -C "${d}" rev-parse HEAD)"
  _run "${d}" commit -q -m blob
  t_assert_eq 1 "${_rc}" "${_out}"
  t_assert_contains "${_out}" "blob.bin"
  t_assert_contains "${_out}" "STAGED CHECKS FAILED (1 of 2): large files"
  t_assert_contains "${_out}" "git commit --no-verify" "the refusal names the bypass"
  t_assert_eq "${head}" "$(git -C "${d}" rev-parse HEAD)" "no commit was made"
  _stage "${d}" large-files.allow "blob.bin | 1024 | fixture"
  _run "${d}" commit -q -m frozen
  t_assert_eq 0 "${_rc}" "the push grades the same freeze file, so the commit must: ${_out}"

  t_case "a staged secret stops the commit although the working tree no longer holds it"
  _stage "${d}" conf/app.txt "token = ${_TOKEN}"
  printf 'clean\n' > "${d}/conf/app.txt"
  _run "${d}" commit -q -m leak
  t_assert_eq 1 "${_rc}" "the commit carries the index, not the working tree: ${_out}"
  t_assert_contains "${_out}" "app.txt:github-pat"
  git -C "${d}" reset -q --hard

  t_case "an unstaged secret in the working tree does not stop a commit that leaves it out"
  printf 'token = %s\n' "${_TOKEN}" >> "${d}/scripts/linux/subject.sh"
  _stage "${d}" README.md "again"
  _run "${d}" commit -q -m unrelated
  t_assert_eq 0 "${_rc}" "the push reads the tree and stops that one: ${_out}"

  t_case "git commit -a and git commit <path> are graded on the index they build"
  _run "${d}" commit -q -a -m all
  t_assert_eq 1 "${_rc}" "the plain index does not show what -a adds: ${_out}"
  t_assert_contains "${_out}" "subject.sh:github-pat"
  _run "${d}" commit -q -m path scripts/linux/subject.sh
  t_assert_eq 1 "${_rc}" "nor what a path on the command line adds: ${_out}"
  git -C "${d}" checkout -q -- scripts/linux/subject.sh

  t_case "a vendored subtree is left to its own repository, the repo's own file beside it is not"
  _stage "${d}" third_party/Vendored/deep/x.txt "token = ${_TOKEN}"
  _run "${d}" commit -q -m vendored
  t_assert_eq 0 "${_rc}" "${_out}"
  t_assert_contains "${_out}" "nothing to scan"
  _stage "${d}" third_party/own.txt "token = ${_TOKEN}"
  _run "${d}" commit -q -m own
  t_assert_eq 1 "${_rc}" "${_out}"
  git -C "${d}" reset -q --hard

  t_case "a commit that only deletes passes without a scan"
  git -C "${d}" rm -q large-files.allow blob.bin
  _run "${d}" commit -q -m delete
  t_assert_eq 0 "${_rc}" "${_out}"
  t_assert_no_grep "${HOOK_TEST_ARGV}" 'lint-secrets'

  t_case "a repo without a wrapper falls back to the bare aggregator, which runs no ratchet check"
  bare="$(_consumer bare)"
  head -c 1048576 /dev/zero > "${bare}/blob.bin"
  git -C "${bare}" add blob.bin
  _run "${bare}" commit -q -m blob
  t_assert_eq 0 "${_rc}" "the large-file check is opt-in with --ratchets, which only a wrapper passes: ${_out}"
  t_assert_contains "${_out}" "linux/scripts/run-lint-gates.sh ${bare} --staged"
  t_assert_contains "${_out}" "STAGED CHECKS OK (1 gate(s))"
  _stage "${bare}" conf/app.txt "token = ${_TOKEN}"
  _run "${bare}" commit -q -m leak
  t_assert_eq 1 "${_rc}" "the secret scan needs no flag: ${_out}"
}

_section_push() {
  local d bare tip

  t_case "a clean push runs the full gates through the wrapper and reaches the remote"
  d="$(_consumer)"
  _push "${d}" 0 README.md "more"
  t_assert_contains "${_out}" "pre-push: scripts/linux/run-lint-gates.sh"
  t_assert_contains "${_out}" "LINT GATES OK (9 gate(s))" "the eight of every consumer and the wrapper's ratchets"
  t_assert_contains "${_out}" "demo-mutations.json: 1 entr(ies)"
  t_assert_grep "${HOOK_TEST_ARGV}" '^lint-shell\.sh$'
  t_assert_grep "${HOOK_TEST_ARGV}" '^--against-hub --root '
  tip="$(git -C "${d}" rev-parse HEAD)"
  t_assert_eq "${tip}" "$(_tip "${d}")"

  t_case "a planted stale recipe passes the commit hook and stops the push, named"
  _stage "${d}" scripts/linux/subject.sh "GUARD=renamed"
  _run "${d}" commit -q -m refactor
  t_assert_eq 0 "${_rc}" "staleness is the push's check: ${_out}"
  _push "${d}" 1
  t_assert_contains "${_out}" "demo.guard" "the recipe to re-point"
  t_assert_contains "${_out}" "demo-mutations.json" "and its manifest"
  t_assert_contains "${_out}" "LINT GATES FAILED (1 of 9): mutation staleness"
  t_assert_contains "${_out}" "git push --no-verify" "the refusal names the bypass"
  t_assert_eq "${tip}" "$(_tip "${d}")" "the remote did not move"

  t_case "a wrapper that prints a failure and exits 1 stops the push"
  _stage "${d}" scripts/linux/subject.sh "GUARD=on"
  _push "${d}" 1 scripts/linux/run-lint-gates.sh "echo 'LINT GATES FAILED (1 of 9): shellcheck'; exit 1"
  t_assert_contains "${_out}" "pre-push: lint gates FAILED, the push is stopped"
  t_assert_eq "${tip}" "$(_tip "${d}")" "a printed failure reached CI once because nothing read the exit code"

  t_case "a push that only deletes a ref checks nothing"
  git -C "${d}" push -q --no-verify origin develop:scratch >/dev/null 2>&1
  _run "${d}" push -q origin :scratch
  t_assert_eq 0 "${_rc}" "${_out}"
  t_assert_contains "${_out}" "no commit to push"
  t_assert_eq "" "$(cat "${HOOK_TEST_ARGV}")" "a minute of gates for a deleted branch teaches --no-verify"

  t_case "without a wrapper the push runs the bare aggregator, staleness included and no ratchet"
  bare="$(_consumer bare)"
  _push "${bare}" 0 README.md "more"
  t_assert_contains "${_out}" "linux/scripts/run-lint-gates.sh ${bare}"
  t_assert_contains "${_out}" "LINT GATES OK (8 gate(s))"
  t_assert_no_grep "${HOOK_TEST_ARGV}" '^--against-hub'
  _push "${bare}" 1 scripts/linux/subject.sh "GUARD=renamed"
  t_assert_contains "${_out}" "demo.guard"
}

_section_extension() {
  local d tip marker

  t_case "the extension point does not run after failed gates"
  d="$(_consumer)"
  marker="${_work}/extension-ran"
  _extension "${d}" "${marker}"
  _push "${d}" 1 scripts/linux/subject.sh "GUARD=renamed"
  t_assert_eq 0 "$(t_rc test ! -e "${marker}")" "a suite run over a tree the gates refused costs time and proves nothing"

  t_case "the extension point runs after green gates, at the top level, with git's hook state cleared and no input"
  _push "${d}" 0 scripts/linux/subject.sh "GUARD=on"
  t_assert_contains "${_out}" "pre-push: scripts/linux/pre-push-checks.sh"
  t_assert_eq "${d}" "$(sed -n 1p "${marker}")" "the script may use paths from the repository root"
  t_assert_eq "prefix=" "$(sed -n 2p "${marker}")" "its fixtures' git calls must not act on this repository"
  t_assert_eq 1 "$(($(sed -n 's/^calls=//p' "${marker}") > 10))" "the gates ran first: $(cat "${marker}")"
  t_assert_eq "stdin=" "$(sed -n 4p "${marker}")" "a script that reads must not wait on the push"
  tip="$(git -C "${d}" rev-parse HEAD)"
  t_assert_eq "${tip}" "$(_tip "${d}")"

  t_case "a failing extension stops the push, with its exit code"
  export EXTENSION_RC=3
  _push "${d}" 1 README.md "third"
  unset EXTENSION_RC
  t_assert_contains "${_out}" "scripts/linux/pre-push-checks.sh FAILED (exit 3), the push is stopped"
  t_assert_eq "${tip}" "$(_tip "${d}")" "the remote did not move"
}

_section_handover() {
  local d hook

  t_case "a repo's own hooks directory hands over to the pair, with the commit's index and the pushed refs"
  d="$(_consumer)"
  mkdir -p "${d}/scripts/git-hooks"
  for hook in pre-commit pre-push; do
    printf '#!/usr/bin/env bash\nexec bash %s/%s "$@"\n' "${HOOKS_REL}" "${hook}" > "${d}/scripts/git-hooks/${hook}"
    chmod +x "${d}/scripts/git-hooks/${hook}"
  done
  git -C "${d}" config core.hooksPath scripts/git-hooks
  printf 'token = %s\n' "${_TOKEN}" >> "${d}/scripts/linux/subject.sh"
  _run "${d}" commit -q -a -m leak
  t_assert_eq 1 "${_rc}" "${_out}"
  t_assert_contains "${_out}" "subject.sh:github-pat" "the index git handed the outer hook reached the staged checks"
  git -C "${d}" checkout -q -- scripts/linux/subject.sh
  _push "${d}" 1 scripts/linux/subject.sh "GUARD=renamed"
  t_assert_contains "${_out}" "demo.guard"
  _run "${d}" push -q origin :develop
  t_assert_contains "${_out}" "no commit to push" "the ref list on standard input reached the pair"
}

# <root> <aggregator dir>: the notice's lines for that root.
_notice() { _LINT_GATES_ROOT="$1" _LINT_GATES_DIR="$2" _lint_gates_hook_notice 2>&1; }

_section_notice() {
  local d out plain hub gates

  t_case "a clone without hooks is told so in one line, and the gates still pass"
  d="$(_consumer)"
  gates="${d}/third_party/ANTfrastructure/linux/scripts"
  git -C "${d}" config --unset core.hooksPath
  out="$(cd "${d}" && bash scripts/linux/run-lint-gates.sh 2>&1)"
  t_assert_eq 0 "$?" "a warning is not a verdict: ${out}"
  t_assert_eq 1 "$(printf '%s\n' "${out}" | grep -c -e 'core.hooksPath is unset')" "${out}"
  t_assert_contains "${out}" "set it once: git config core.hooksPath ${HOOKS_REL}"
  t_assert_eq "LINT GATES OK (9 gate(s))" "$(printf '%s\n' "${out}" | tail -n 1)" "the verdict stays the last line"
  t_assert_contains "$(cd "${d}" && bash scripts/linux/run-lint-gates.sh --staged 2>&1)" "core.hooksPath is unset" \
    "the staged checks run by hand say it too"

  t_case "CI gets no such line"
  out="$(cd "${d}" && CI=true bash scripts/linux/run-lint-gates.sh 2>&1)"
  t_assert_contains "${out}" "LINT GATES OK"
  t_assert_eq 0 "$(printf '%s\n' "${out}" | grep -c -e 'hooksPath')" "${out}"

  t_case "a clone with any hooks path set gets no such line"
  git -C "${d}" config core.hooksPath scripts/git-hooks
  t_assert_eq "" "$(_notice "${d}" "${gates}")" "a repo's own hook directory is a decision, not a gap"
  git -C "${d}" config --unset core.hooksPath
  t_assert_contains "$(_notice "${d}" "${gates}")" "core.hooksPath is unset"

  t_case "a tree that is not a git checkout gets the aggregator's refusal and no such line"
  plain="$(mktemp -d "${_work}/plain.XXXXXX")"
  out="$(bash "${gates}/run-lint-gates.sh" "${plain}" 2>&1)"
  t_assert_eq 2 "$?"
  t_assert_contains "${out}" "is not a git checkout"
  t_assert_eq "" "$(_notice "${plain}" "${gates}")"

  t_case "the hub with its own hooks configured gets no such line, and without them it is sent to make hooks"
  hub="$(mktemp -d "${_work}/hubroot.XXXXXX")"
  mkdir -p "${hub}/linux/scripts"
  git -C "${hub}" init -q
  git -C "${hub}" config core.hooksPath linux/host-config/git-hooks
  t_assert_eq "" "$(_notice "${hub}" "${hub}/linux/scripts")"
  git -C "${hub}" config --unset core.hooksPath
  out="$(_notice "${hub}" "${hub}/linux/scripts")"
  t_assert_contains "${out}" "set it once: make hooks"
  t_assert_eq 0 "$(printf '%s\n' "${out}" | grep -c -e 'templates/git-hooks')" "the consumer pair is not the hub's"
}

_hub_copy "${_work}/hub"
t_sections _section_commit _section_push _section_extension _section_handover _section_notice -- "$@"
t_summary
