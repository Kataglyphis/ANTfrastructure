#!/usr/bin/env bash
# Tests for check_crlf_guard, the inline preflight gate: a tracked shell script
# whose WORKING-TREE bytes carry CR must be named and fail in every shape git can
# report (w/crlf, w/mixed, w/-text), an index-only CRLF must not, the scope is
# lint-shell.sh's, and any stage failing must not pass on the empty result.
# docs/code-quality-tooling.md#crlf-guard-the-worked-example
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
REPO_ROOT="$(cd "${TESTS_DIR}/../../.." && pwd)"

FN_SRC="$(t_fn_src "${REPO_ROOT}/linux/scripts/preflight.sh" check_crlf_guard)" || exit 1
SET_LINE="$(grep -m1 -e '^set -' "${REPO_ROOT}/linux/scripts/preflight.sh")"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
printf '%s\n' "${FN_SRC}" > "${WORK}/guard.sh"

REPO=""
_repo() {
  REPO="${WORK}/$1"
  mkdir -p "${REPO}"
  git -C "${REPO}" init -q
  git -C "${REPO}" config user.email tester@example.invalid
  git -C "${REPO}" config user.name tester
  git -C "${REPO}" config core.autocrlf false
  mkdir -p "${REPO}/linux/scripts"
  cp "${REPO_ROOT}/linux/scripts/lint-shell.sh" "${REPO}/linux/scripts/lint-shell.sh"
  printf 'echo hi\n' > "${REPO}/good.sh"
  printf 'echo bad\n' > "${REPO}/bad.sh"
  git -C "${REPO}" add good.sh bad.sh
  git -C "${REPO}" commit -qm baseline
  [ $# -gt 1 ] && printf '%b' "$2" > "${REPO}/bad.sh"
  return 0
}

_eol() { git -C "${REPO}" ls-files --eol -- "$1" | awk -F'\t' -v n="$2" '{split($1,c,/[ \t]+/); print c[n]}'; }

OUT=""; rc=0
_guard() {
  OUT="$(cd "${1:-${REPO}}" && bash -c "${SET_LINE}"'
source "$1"
check_crlf_guard' _ "${WORK}/guard.sh" 2>&1)"
  rc=$?
}

_named() { printf '%s' "${OUT}" | grep -c "$1"; }

t_case "an LF-only working tree passes and says what it looked at"
_repo lf; _guard
t_assert_eq "0" "${rc}" "nothing carries CR, so the guard must pass"
t_assert_contains "${OUT}" "no w/crlf, w/mixed or w/-text shell scripts in the working tree"

t_case "a wholly-CRLF tracked *.sh is named and fails"
_repo crlf 'echo bad\r\n'; _guard
t_assert_eq "1" "${rc}" "printing is not enough; a w/crlf offender must fail"
t_assert_contains "${OUT}" "CRLF working-tree line endings detected"
t_assert_contains "${OUT}" "w/crlf  bad.sh"
t_assert_eq "0" "$(_named good.sh)" "the LF sibling is not an offender"
t_assert_contains "${OUT}" "git checkout --" "and it says how to re-materialize LF"

t_case "ONE CRLF line among LF lines (w/mixed) is named and fails"
_repo mixed 'echo one\necho two\r\necho three\n'
t_assert_eq "w/mixed" "$(_eol bad.sh 2)" "git reports a partly-rewritten file as w/mixed, not w/crlf"
_guard
t_assert_eq "1" "${rc}" "the realistic accident: an editor or merge rewrote SOME lines"
t_assert_contains "${OUT}" "CRLF working-tree line endings detected"
t_assert_contains "${OUT}" "w/mixed  bad.sh" "the shape is reported so the fix is obvious"
t_assert_eq "0" "$(_named good.sh)" "the LF sibling is not an offender"

t_case "a lone CR (git calls it w/-text) is named and fails"
_repo lonecr 'echo one\necho two\rcho three\n'
t_assert_eq "w/-text" "$(_eol bad.sh 2)" "a bare CR makes git call the file -text"
_guard
t_assert_eq "1" "${rc}" "a bare CR breaks bash exactly like CRLF does"
t_assert_contains "${OUT}" "w/-text  bad.sh"

t_case "the w/mixed verdict survives a .gitattributes eol=lf pin"
_repo attr 'echo one\necho two\r\n'
printf '*.sh text eol=lf\n' > "${REPO}/.gitattributes"
git -C "${REPO}" add .gitattributes
_guard
t_assert_eq "1" "${rc}" "the attr normalises the NEXT checkout, not the bytes on disk now"
t_assert_contains "${OUT}" "w/mixed"

t_case "CRLF in the index but LF in the working tree is NOT an offender"
_repo idx 'echo bad\r\n'
git -C "${REPO}" add bad.sh
printf 'echo bad\n' > "${REPO}/bad.sh"
t_assert_eq "i/crlf" "$(_eol bad.sh 1)" "the fixture really is CRLF in the index"
t_assert_eq "w/lf" "$(_eol bad.sh 2)" "and LF in the working tree"
_guard
t_assert_eq "0" "${rc}" "buildkit snapshots the worktree, so only the w/ column decides"
t_assert_eq "0" "$(_named bad.sh)" "an index-only CRLF must not be named"

t_case "a tracked *.sh deleted from the working tree is not an offender"
_repo gone
rm "${REPO}/bad.sh"
t_assert_eq "w/" "$(_eol bad.sh 2)" "git prints an empty w/ column for a missing file"
_guard
t_assert_eq "0" "${rc}" "missing is not CRLF"

t_case "git failing is a loud failure, not an empty pass"
mkdir -p "${WORK}/nogit"
_guard "${WORK}/nogit"
t_assert_eq "1" "${rc}" "git ls-files failing must not read as a clean tree"
t_assert_contains "${OUT}" "__git-ls-files-FAILED__"

t_case "an extension-less script on a shell shebang is in scope, like the commit hook"
_repo hook
mkdir -p "${REPO}/git-hooks"
printf '#!/usr/bin/env bash\necho hi\r\n' > "${REPO}/git-hooks/pre-commit"
git -C "${REPO}" add git-hooks/pre-commit
_guard
t_assert_eq "1" "${rc}" "a hook cannot carry a .sh suffix, and CR breaks it exactly the same"
t_assert_contains "${OUT}" "w/mixed  git-hooks/pre-commit"

t_case "an extension-less file with no shell shebang is NOT an offender"
_repo notes
printf 'plain\r\ntext\r\n' > "${REPO}/NOTES"
git -C "${REPO}" add NOTES
_guard
t_assert_eq "0" "${rc}" "the scope is lint-shell.sh's answer, not every tracked file"
t_assert_eq "0" "$(_named NOTES)" "prose is allowed to carry CR"

t_case "the scope owner going missing is a loud failure, not an empty scope that passes"
_repo noowner
rm "${REPO}/linux/scripts/lint-shell.sh"
_guard
t_assert_eq "1" "${rc}" "no lint-shell.sh means no answer to 'what is a shell script'"
t_assert_contains "${OUT}" "__git-ls-files-FAILED__"

t_case "the pipefail this guard needs is pinned in preflight.sh, not hard-coded here"
t_assert_contains "${SET_LINE}" "pipefail" \
  "the loud-failure cases run under preflight.sh's own set line; dropping pipefail there must break them"

t_summary
