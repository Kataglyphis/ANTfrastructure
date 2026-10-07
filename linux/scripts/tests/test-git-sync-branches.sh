#!/usr/bin/env bash
# git-sync-branches.sh moves owned checkouts to their branch tip, fast-forward only, and leaves foreign submodules pinned.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"

SYNC="${TESTS_DIR}/../git-sync-branches.sh"
_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT
export GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always
export GIT_CONFIG_KEY_1=init.defaultBranch GIT_CONFIG_VALUE_1=develop
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# _remote <owner/repo> [default-branch]: a bare remote under the calling fixture's _root, with one commit on its default branch.
_remote() {
  local bare="${_root}/remotes/$1.git" seed
  seed="$(mktemp -d "${_work}/seed.XXXXXX")"
  git init -q -b "${2:-develop}" "${seed}"
  git -C "${seed}" commit -q --allow-empty -m init
  git init -q --bare -b "${2:-develop}" "${bare}"
  git -C "${seed}" push -q "${bare}" HEAD
  printf '%s' "${bare}"
}

# _advance <bare> <branch>: one more commit on the remote branch.
_advance() {
  local c; c="$(mktemp -d "${_work}/adv.XXXXXX")"
  git clone -q -b "$2" "$1" "${c}"
  git -C "${c}" commit -q --allow-empty -m next
  git -C "${c}" push -q origin "$2"
}

# _fixture: prints a clone of me/app holding me/lib (branch = develop) and other/vendor (no branch, default trunk).
_fixture() {
  local _root app lib vendor seed d
  _root="$(mktemp -d "${_work}/fx.XXXXXX")"
  app="$(_remote me/app)"; lib="$(_remote me/lib)"; vendor="$(_remote other/vendor trunk)"
  seed="$(mktemp -d "${_work}/app.XXXXXX")"
  git clone -q "${app}" "${seed}"
  git -C "${seed}" submodule add -q -b develop "${lib}" lib
  git -C "${seed}" submodule add -q "${vendor}" vendor
  git -C "${seed}" commit -q -m subs
  git -C "${seed}" push -q origin develop
  _advance "${app}" develop; _advance "${lib}" develop; _advance "${vendor}" trunk
  d="$(mktemp -d "${_work}/clone.XXXXXX")"
  git clone -q --recurse-submodules "${app}" "${d}"
  printf '%s' "${d}"
}

_tip() { git -C "$1" rev-parse "origin/$2"; }
_head() { git -C "$1" rev-parse HEAD; }

t_case "owned checkouts reach their branch tip; a foreign submodule stays pinned and is named"
d="$(_fixture)"
pin="$(_head "${d}/vendor")"
git -C "${d}" fetch -q
git -C "${d}" reset -q --hard HEAD~1
out="$(t_out bash "${SYNC}" --repo "${d}")"
t_assert_eq "$(_tip "${d}" develop)" "$(_head "${d}")" "superproject at origin/develop"
t_assert_eq develop "$(git -C "${d}/lib" rev-parse --abbrev-ref HEAD)" "owned submodule on its declared branch"
t_assert_eq "$(_tip "${d}/lib" develop)" "$(_head "${d}/lib")" "owned submodule at its tip"
t_assert_eq "${pin}" "$(_head "${d}/vendor")" "foreign submodule untouched"
t_assert_contains "${out}" "PIN   vendor" "the pinned one is reported"
t_assert_contains "${out}" "lib" "the moved gitlink is listed as drift"

t_case "--all moves the foreign submodule to its remote's default branch"
d="$(_fixture)"
t_assert_eq 0 "$(t_rc bash "${SYNC}" --repo "${d}" --all)" "exit code"
t_assert_eq trunk "$(git -C "${d}/vendor" rev-parse --abbrev-ref HEAD)" "remote default used without branch ="
t_assert_eq "$(_tip "${d}/vendor" trunk)" "$(_head "${d}/vendor")" "at its tip"

t_case "--dry-run changes nothing"
d="$(_fixture)"
before="$(_head "${d}/lib")"
out="$(t_out bash "${SYNC}" --repo "${d}" --dry-run)"
t_assert_eq "${before}" "$(_head "${d}/lib")" "lib not moved"
t_assert_contains "${out}" "PLAN  lib" "the plan names it"

t_case "a dirty submodule is skipped, not overwritten"
d="$(_fixture)"
before="$(_head "${d}/lib")"
printf 'x\n' > "${d}/lib/f"; git -C "${d}/lib" add f
out="$(t_out bash "${SYNC}" --repo "${d}")"
t_assert_eq "${before}" "$(_head "${d}/lib")" "dirty lib not moved"
t_assert_contains "${out}" "SKIP  lib" "reported"

t_case "a diverged local branch fails the run, and the rest still syncs (mutation: no ff-only)"
d="$(_fixture)"
git -C "${d}/lib" checkout -q -B develop HEAD
git -C "${d}/lib" commit -q --allow-empty -m local
t_assert_eq 1 "$(t_rc bash "${SYNC}" --repo "${d}")" "exit code"
t_assert_eq "$(_tip "${d}" develop)" "$(_head "${d}")" "superproject still synced"
t_assert_eq 1 "$(git -C "${d}/lib" rev-list --count origin/develop..HEAD)" "the local commit survives"

t_case "url_owner reads https and scp forms alike"
eval "$(sed -n '/^url_owner()/,/^}/p' "${SYNC}")"
t_assert_eq github.com/Kataglyphis "$(url_owner https://github.com/Kataglyphis/OxidANT.git)" "https"
t_assert_eq github.com/Kataglyphis "$(url_owner git@github.com:Kataglyphis/OxidANT.git)" "scp"
t_assert_eq github.com/nlohmann "$(url_owner https://github.com/nlohmann/json.git)" "foreign"

t_summary
