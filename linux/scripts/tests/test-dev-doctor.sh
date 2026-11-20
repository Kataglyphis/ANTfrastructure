#!/usr/bin/env bash
# dev-doctor.sh on fixture clones with a fake engine and a fake uv: each stale part is one line and exit 1, and nothing is written.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
DOCTOR="${TESTS_DIR}/../dev-doctor.sh"
work="$(t_mktemp -d)"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
UV_PIN="$(sed -n 's/^UV_VERSION=//p' "${TESTS_DIR}/../01-core/versions.env")"

# A fake engine whose image is as old as FAKE_IMAGE_DATE says, and a uv reporting FAKE_UV.
mkdir -p "${work}/bin"
printf '#!/usr/bin/env bash\n[ -n "${FAKE_IMAGE_DATE:-}" ] && echo "${FAKE_IMAGE_DATE}"\n' > "${work}/bin/engine"
printf '#!/usr/bin/env bash\necho "uv ${FAKE_UV}"\n' > "${work}/bin/uv"
chmod +x "${work}/bin/"*

# _commit_to <base> <clone name> <message>: a clone of <base>/origin.git that pushes one empty commit to develop.
_commit_to() {
  git clone -q "$1/origin.git" "$1/$2" 2>/dev/null
  git -C "$1/$2" commit -q --allow-empty -m "$3"
  git -C "$1/$2" push -q origin HEAD:develop
}
# _clone: a bare origin with develop, a clone of it with an absolute hooks path; prints the base directory.
_clone() {
  local d; d="$(mktemp -d "${work}/c.XXXXXX")"
  git init -q --bare -b develop "${d}/origin.git"
  _commit_to "${d}" clone base
  git -C "${d}/clone" config core.hooksPath "${d}/hooks"
  printf '%s' "${d}"
}
_doctor() {
  FAKE_IMAGE_DATE="${FAKE_IMAGE_DATE-$(date -u +%Y-%m-%dT%H:%M:%SZ)}" FAKE_UV="${FAKE_UV:-${UV_PIN}}" \
    DOCTOR_ENGINE="${work}/bin/engine" PATH="${work}/bin:${PATH}" bash "${DOCTOR}" "$1" 2>&1
}

t_case "a current clone with a fresh image and the pinned uv is clean"
d="$(_clone)"
t_assert_eq 0 "$(t_rc _doctor "${d}/clone")" "$(_doctor "${d}/clone")"
t_assert_contains "$(_doctor "${d}/clone")" "dev-doctor: nothing stale"

t_case "commits on origin the clone lacks are named, and the check writes no ref"
_commit_to "${d}" other ahead
refs_before="$(git -C "${d}/clone" for-each-ref | sha256sum)"
t_assert_eq 1 "$(t_rc _doctor "${d}/clone")"
t_assert_contains "$(_doctor "${d}/clone")" "a commit this clone does not have: fetch"
t_assert_eq "${refs_before}" "$(git -C "${d}/clone" for-each-ref | sha256sum)" "read-only: ls-remote, not fetch"
git -C "${d}/clone" fetch -q && git -C "${d}/clone" reset -q --hard HEAD~0
t_assert_contains "$(_doctor "${d}/clone")" "HEAD is 1 commit(s) behind origin's develop"

t_case "a hooks path unset or relative, a missing submodule, an old image and another uv are each one line"
d="$(_clone)"
git -C "${d}/clone" config --unset core.hooksPath
t_assert_contains "$(_doctor "${d}/clone")" "STALE  core.hooksPath is unset"
t_assert_eq 1 "$(t_rc _doctor "${d}/clone")" "a clone without hooks is stale"
git -C "${d}/clone" config core.hooksPath third_party/ANTfrastructure/shared/linux/templates/git-hooks
t_assert_contains "$(_doctor "${d}/clone")" "is relative, so a linked worktree"
git -C "${d}/clone" config core.hooksPath "${d}/hooks"
sub="$(_clone)"
git -C "${d}/clone" -c protocol.file.allow=always submodule add -q "${sub}/origin.git" third_party/sub 2>/dev/null
git -C "${d}/clone" commit -q -m sub
rm -rf "${d}/clone/third_party/sub" && mkdir "${d}/clone/third_party/sub"
t_assert_contains "$(_doctor "${d}/clone")" "submodule third_party/sub is not checked out"
t_assert_contains "$(FAKE_IMAGE_DATE=2026-01-01T00:00:00Z _doctor "${d}/clone")" "days old (over 7)"
t_assert_contains "$(FAKE_IMAGE_DATE='' _doctor "${d}/clone")" "no local copy of"
t_assert_contains "$(FAKE_UV=0.0.1 _doctor "${d}/clone")" "uv on PATH is 0.0.1, the pin is ${UV_PIN}"
t_assert_contains "$(FAKE_UV=0.0.1 _doctor "${d}/clone")" "stale item(s); nothing was changed"

t_case "a root that is not a checkout is a usage error, not a clean report"
t_assert_eq 2 "$(t_rc bash "${DOCTOR}" "${work}")"
t_assert_eq 2 "$(t_rc bash "${DOCTOR}")"

t_summary
