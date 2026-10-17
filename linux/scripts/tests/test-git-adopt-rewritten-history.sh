#!/usr/bin/env bash
# git-adopt-rewritten-history.sh moves a checkout and its submodules onto rewritten remotes, keeps the local work, drops the old blobs.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"

ADOPT="${TESTS_DIR}/../git-adopt-rewritten-history.sh"
_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT
source "${TESTS_DIR}/git-fixture-env.sh"
export FILTER_BRANCH_SQUELCH_WARNING=1

# _big <file>: 600 KB of noise, a blob the rewrite drops.
_big() { head -c 614400 /dev/urandom > "$1"; }

# _rewrite <bare> <index-filter>: rewrites every branch of a bare remote the way a history purge does, and prints "old new" per commit.
_rewrite() {
  local c; c="$(mktemp -d "${_work}/rw.XXXXXX")/m.git"
  git clone -q --mirror "$1" "${c}"
  # Bare: filter-branch checks no working tree there.
  (cd "${c}" && git filter-branch --index-filter "$2" -- --all >/dev/null)
  paste -d' ' <(git -C "${c}" rev-list --reverse refs/original/refs/heads/develop) <(git -C "${c}" rev-list --reverse develop)
  git -C "${c}" for-each-ref --format='delete %(refname)' refs/original | git -C "${c}" update-ref --stdin
  git -C "${c}" push -q --force --mirror "$1"
}

# _fixture: me/app holding me/lib as "lib", each with a big blob added and deleted; prints a recursive clone's path.
_fixture() {
  local root seed d
  root="$(mktemp -d "${_work}/fx.XXXXXX")"
  seed="${root}/lib-seed"
  git init -q "${seed}"
  echo one > "${seed}/s.txt"; _big "${seed}/lib-big.bin"
  git -C "${seed}" add . && git -C "${seed}" commit -q -m "lib: big"
  git -C "${seed}" rm -q lib-big.bin && git -C "${seed}" commit -q -m "lib: big gone"
  git clone -q --bare "${seed}" "${root}/lib.git"
  seed="${root}/app-seed"
  git init -q "${seed}"
  echo one > "${seed}/o.txt"; _big "${seed}/app-big.bin"
  git -C "${seed}" add . && git -C "${seed}" commit -q -m "app: big"
  git -C "${seed}" submodule add -q "${root}/lib.git" lib && git -C "${seed}" commit -q -m "app: lib"
  git -C "${seed}" rm -q app-big.bin && git -C "${seed}" commit -q -m "app: big gone"
  git clone -q --bare "${seed}" "${root}/app.git"
  d="${root}/clone"
  git clone -q --recurse-submodules "${root}/app.git" "${d}"
  printf '%s' "${d}"
}

# _purge <clone>: rewrites lib, then app with its gitlinks re-pointed, as the family's history purge does.
_purge() {
  local root map
  root="$(dirname "$1")"
  map="${root}/lib.map"
  _rewrite "${root}/lib.git" 'git rm -q --cached --ignore-unmatch lib-big.bin' > "${map}"
  _rewrite "${root}/app.git" "git rm -q --cached --ignore-unmatch app-big.bin
    c=\$(git ls-files -s lib | cut -d' ' -f2); [ -z \"\$c\" ] || git update-index --cacheinfo 160000,\$(awk -v o=\$c '\$1==o {print \$2}' '${map}'),lib" >/dev/null
}

_blob() { git -C "$1" rev-parse "$2"; }
_has() { git -C "$1" cat-file -e "$2" 2>/dev/null; }

t_case "a rewritten superproject and its detached submodule move over; local work is saved, the old blobs leave the disk"
d="$(_fixture)"
app_big="$(_blob "${d}" HEAD~2:app-big.bin)"; lib_big="$(_blob "${d}/lib" HEAD~1:lib-big.bin)"
echo unpushed > "${d}/mine.txt" && git -C "${d}" add mine.txt && git -C "${d}" commit -q -m "never pushed"
git -C "${d}" tag kept-here HEAD~3
echo stashed >> "${d}/o.txt" && git -C "${d}" stash -q
echo local-edit >> "${d}/o.txt"; echo lib-edit >> "${d}/lib/s.txt"
_purge "${d}"
# An IDE's background fetch: the rewrite must still be seen once origin/* already names the new commits.
git -C "${d}" fetch -q
before="$(git -C "${d}" rev-parse HEAD)"
out="$(t_out bash "${ADOPT}" --dry-run --backup "${_work}/dry" "${d}")"
t_assert_eq "${before}" "$(git -C "${d}" rev-parse HEAD)" "--dry-run leaves HEAD where it was"
t_assert_fails test -e "${_work}/dry"
t_assert_contains "${out}" "would run: git -C ${d} reset" "--dry-run names the reset"
out="$(t_out bash "${ADOPT}" --backup "${_work}/bk" "${d}")"
t_assert_eq "$(git -C "$(dirname "${d}")/app.git" rev-parse develop)" "$(git -C "${d}" rev-parse origin/develop)" "origin/develop is the rewritten tip"
t_assert_contains "${out}" "develop has 1 commit(s) that never reached origin" "the never-pushed commit is named"
t_assert_ok grep -q "never pushed" "${_work}/bk/clone/develop/0001-never-pushed.patch"
t_assert_eq "$(git -C "${d}" rev-parse origin/develop)" "$(git -C "${d}" rev-parse develop)" "develop sits on the rewritten history"
t_assert_ok grep -q local-edit "${d}/o.txt"
t_assert_ok grep -q lib-edit "${d}/lib/s.txt"
t_assert_ok grep -q stashed "${_work}/bk/clone/stash-0.patch"
t_assert_eq "$(git -C "${d}" ls-tree HEAD lib | awk '{print $3}')" "$(git -C "${d}/lib" rev-parse HEAD)" "the detached submodule is at the new gitlink"
t_assert_ok grep -q "^kept-here " "${_work}/bk/clone/local-tags.txt"
t_assert_fails git -C "${d}" rev-parse -q --verify refs/tags/kept-here
t_assert_fails _has "${d}" "${app_big}"
t_assert_fails _has "${d}/lib" "${lib_big}"
out="$(t_out bash "${ADOPT}" --backup "${_work}/bk2" "${d}")"
t_assert_eq "" "$(printf '%s\n' "${out}" | grep -E 'moves to|rewritten|re-applied|did not apply')" "a second run has nothing to move"
t_assert_eq 1 "$(grep -c local-edit "${d}/o.txt")" "and leaves the uncommitted edit as it is"

t_case "a submodule on its branch, as the branch-sync script leaves it, moves with that branch"
on_branch="$(_fixture)"
git -C "${on_branch}/lib" switch -q develop
lib_big="$(_blob "${on_branch}/lib" HEAD~1:lib-big.bin)"
_purge "${on_branch}"
out="$(t_out bash "${ADOPT}" --backup "${_work}/bk4" "${on_branch}")"
t_assert_contains "${out}" "clone/lib: develop moves to the rewritten origin/develop" "the branch is named"
t_assert_eq refs/heads/develop "$(git -C "${on_branch}/lib" symbolic-ref HEAD)" "HEAD stays attached to develop"
t_assert_eq 0 "$(git -C "${on_branch}/lib" rev-list --count HEAD...origin/develop)" "and develop is origin's rewritten tip"
t_assert_fails _has "${on_branch}/lib" "${lib_big}"

t_case "a remote that was not rewritten is only fast-forwarded, and keeps its reflog"
d="$(_fixture)"
c="$(mktemp -d "${_work}/adv.XXXXXX")"
git clone -q "$(dirname "${d}")/app.git" "${c}" && git -C "${c}" commit -q --allow-empty -m next && git -C "${c}" push -q origin develop
reflog="$(git -C "${d}" reflog | wc -l)"
out="$(t_out bash "${ADOPT}" --backup "${_work}/bk3" "${d}")"
t_assert_contains "${out}" "develop fast-forwards" "a plain update fast-forwards"
t_assert_eq "" "$(printf '%s\n' "${out}" | grep -E 'rewritten|dropped')" "no rewrite, no gc"
t_assert_eq "$(git -C "${d}" rev-parse origin/develop)" "$(git -C "${d}" rev-parse develop)" "develop reached origin/develop"
t_assert_ok test "$(git -C "${d}" reflog | wc -l)" -gt "${reflog}"

t_summary
