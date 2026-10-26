#!/usr/bin/env bash
# Share the Git bootstrap fixture while each caller supplies its own driver and wrapper layout.
[ -n "${_RENOVATE_BOOTSTRAP_FIXTURE_LOADED:-}" ] && return 0
_RENOVATE_BOOTSTRAP_FIXTURE_LOADED=1

# shellcheck source=test-harness.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-harness.sh"

# Caller-supplied stub bytes keep each wrapper's argument and status contract visible.
t_renovate_bootstrap_driver() {
  local seed="$1"
  mkdir -p "${seed}/linux/scripts" || return 1
  cat > "${seed}/linux/scripts/renovate-local.sh"
}

# Both temporary repositories must use the same branch and checked callback setup.
_t_renovate_bootstrap_repo() {
  local repo="$1" callback="$2"
  mkdir -p "${repo}" || return 1
  git -C "${repo}" init -q -b develop || return 1
  "${callback}" "${repo}"
}

# Each suite plants its own hub driver; the Git remote and branch stay the same.
_t_renovate_bootstrap_seed() {
  local base="$1" seed_callback="$2" seed remote sha
  seed="${base}/seed"
  remote="${base}/hub.git"
  _t_renovate_bootstrap_repo "${seed}" "${seed_callback}" || return 1
  t_git_commit "${seed}" || return 1
  sha="$(git -C "${seed}" rev-parse HEAD)" || return 1
  git clone --quiet --bare "${seed}" "${remote}" || return 1
  git -C "${remote}" symbolic-ref HEAD refs/heads/develop || return 1
  printf '%s' "${sha}"
}

# Each suite plants its own copied wrapper before the pinned gitlink is committed.
_t_renovate_bootstrap_consumer() {
  local base="$1" sha="$2" consumer_callback="$3" repo remote
  repo="${base}/consumer"
  remote="${base}/hub.git"
  _t_renovate_bootstrap_repo "${repo}" "${consumer_callback}" || return 1
  printf '[submodule "third_party/ANTfrastructure"]\n\tpath = third_party/ANTfrastructure\n\turl = %s\n' \
    "${remote}" > "${repo}/.gitmodules" || return 1
  git -C "${repo}" add -- .gitmodules scripts || return 1
  git -C "${repo}" update-index --add --cacheinfo \
    "160000,${sha},third_party/ANTfrastructure" || return 1
  git -C "${repo}" -c user.email=t@t -c user.name=t commit -qm fixture || return 1
  printf '\n# preserve this config byte for byte\n' >> "${repo}/.git/config" || return 1
  cp -p "${repo}/.git/config" "${base}/config.before" || return 1
  printf '%s' "${repo}"
}

# t_renovate_bootstrap_fixture <base> <seed-callback> <consumer-callback>: print the consumer path.
t_renovate_bootstrap_fixture() {
  local base="$1" seed_callback="$2" consumer_callback="$3" sha
  sha="$(_t_renovate_bootstrap_seed "${base}" "${seed_callback}")" || return 1
  _t_renovate_bootstrap_consumer "${base}" "${sha}" "${consumer_callback}"
}

# t_renovate_bootstrap_run <consumer> <tmp-root> [wrapper-args...]: keep the real wrapper status.
t_renovate_bootstrap_run() {
  local repo="$1" tmp_root="$2"
  shift 2
  DRIVER_ARGS="${repo%/consumer}/driver.args" GIT_ALLOW_PROTOCOL=file TMPDIR="${tmp_root}" \
    bash "${repo}/scripts/linux/renovate-local.sh" "$@"
}

# A failed preview must not leave a checkout, change config, or invoke the driver.
t_renovate_bootstrap_assert_pristine() {
  local repo="$1" base
  base="${repo%/consumer}"
  t_assert_fails test -e "${repo}/third_party"
  t_assert_ok cmp -s "${base}/config.before" "${repo}/.git/config"
  t_assert_fails test -e "${base}/driver.args"
}
