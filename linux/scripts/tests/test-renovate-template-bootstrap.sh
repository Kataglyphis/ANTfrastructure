#!/usr/bin/env bash
# The copied wrapper bootstraps only a real apply; live Renovate and a Windows container are outside this fixture.
set -u
# shellcheck source=linux/scripts/tests/test-harness.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-harness.sh"
TEMPLATES="$(cd "${_T_SCRIPTS}/../../shared/linux/templates" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

make_consumer() {
  local base="${WORK}/$1" seed="${WORK}/$1/seed" remote="${WORK}/$1/hub.git"
  local repo="${WORK}/$1/consumer" sha
  mkdir -p "${seed}/linux/scripts" "${repo}/scripts/linux/lib"
  git -C "${seed}" init -q -b develop
  git -C "${seed}" config user.name Fixture
  git -C "${seed}" config user.email fixture@example.invalid
  cat > "${seed}/linux/scripts/renovate-local.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${DRIVER_ARGS:?}"
if [ "${DRIVER_SIGNAL:-0}" = 1 ]; then kill -TERM "$PPID"; fi
exit "${DRIVER_EXIT:-0}"
SH
  printf '[submodule "nested"]\n\tpath = nested\n\turl = /missing/nested\n' > "${seed}/.gitmodules"
  git -C "${seed}" add .gitmodules linux/scripts/renovate-local.sh
  git -C "${seed}" update-index --add --cacheinfo "160000,1111111111111111111111111111111111111111,nested"
  git -C "${seed}" commit -qm seed
  sha="$(git -C "${seed}" rev-parse HEAD)"
  git clone --quiet --bare "${seed}" "${remote}"
  git -C "${remote}" symbolic-ref HEAD refs/heads/develop

  git -C "${repo}" init -q -b develop
  git -C "${repo}" config user.name Fixture
  git -C "${repo}" config user.email fixture@example.invalid
  cp "${TEMPLATES}/renovate-local.sh" "${repo}/scripts/linux/renovate-local.sh"
  cp "${TEMPLATES}/antfrastructure.sh" "${repo}/scripts/linux/lib/antfrastructure.sh"
  printf '[submodule "third_party/ANTfrastructure"]\n\tpath = third_party/ANTfrastructure\n\turl = %s\n' "${remote}" > "${repo}/.gitmodules"
  git -C "${repo}" add .gitmodules scripts/linux
  git -C "${repo}" update-index --add --cacheinfo "160000,${sha},third_party/ANTfrastructure"
  git -C "${repo}" commit -qm consumer
  printf '\n# preserve the consumer config byte for byte\n' >> "${repo}/.git/config"
  cp -p "${repo}/.git/config" "${base}/config.before"
  printf '%s' "${repo}"
}

run_wrapper() {
  local repo="$1"; shift
  DRIVER_ARGS="${repo%/consumer}/driver.args" GIT_ALLOW_PROTOCOL=file TMPDIR="${WORK}" \
    bash "${repo}/scripts/linux/renovate-local.sh" "$@"
}

t_case "report and dry-run refuse an unavailable hub without cloning it"
repo="$(make_consumer read_only)"
t_assert_fails run_wrapper "${repo}"
t_assert_fails run_wrapper "${repo}" --apply --dry-run
t_assert_fails test -e "${repo}/third_party/ANTfrastructure/.git"
t_assert_fails test -e "${repo}/third_party/ANTfrastructure/linux/scripts/renovate-local.sh"
t_assert_ok cmp -s "${WORK}/read_only/config.before" "${repo}/.git/config"
t_assert_fails test -e "${WORK}/read_only/driver.args"

t_case "an initialized old hub reports its missing driver without bootstrap"
repo="$(make_consumer old_pin)"
env GIT_ALLOW_PROTOCOL=file git -C "${repo}" submodule update --init -- third_party/ANTfrastructure >/dev/null 2>&1
rm "${repo}/third_party/ANTfrastructure/linux/scripts/renovate-local.sh"
old_pin_rc=0
old_pin_output="$(run_wrapper "${repo}" --apply 2>&1)" || old_pin_rc=$?
t_assert_eq 1 "${old_pin_rc}"
t_assert_contains "${old_pin_output}" "ANTfrastructure file not found"
t_assert_ok test -e "${repo}/third_party/ANTfrastructure/.git"

t_case "apply initializes only the direct hub before invoking the driver"
repo="$(make_consumer apply)"
t_assert_rc 0 run_wrapper "${repo}" --apply --managers pub
t_assert_eq "${repo}" "$(sed -n '1p' "${WORK}/apply/driver.args")"
t_assert_eq --apply "$(sed -n '2p' "${WORK}/apply/driver.args")"
t_assert_eq "$(git -C "${repo}" rev-parse HEAD:third_party/ANTfrastructure)" \
  "$(git -C "${repo}/third_party/ANTfrastructure" rev-parse HEAD)"
t_assert_fails test -e "${repo}/third_party/ANTfrastructure/nested/.git"
t_assert_eq "" "$(git -C "${repo}" status --porcelain)"

t_case "a driver refusal exits two and keeps its initialized hub for review"
repo="$(make_consumer refused)"
DRIVER_EXIT=2 t_assert_rc 2 run_wrapper "${repo}" --apply
t_assert_ok test -f "${repo}/third_party/ANTfrastructure/linux/scripts/renovate-local.sh"

t_case "a fatal driver status restores the config and originally absent directories"
repo="$(make_consumer fatal)"
DRIVER_EXIT=7 t_assert_rc 7 run_wrapper "${repo}" --apply
t_assert_ok cmp -s "${WORK}/fatal/config.before" "${repo}/.git/config"
t_assert_fails test -e "${repo}/third_party"
t_assert_eq "$(git -C "${repo}" rev-parse HEAD:third_party/ANTfrastructure)" \
  "$(git -C "${repo}" ls-files --stage -- third_party/ANTfrastructure | cut -d' ' -f2)"

t_case "a signal after bootstrap restores the initially missing hub"
repo="$(make_consumer signal)"
DRIVER_SIGNAL=1 t_assert_rc 143 run_wrapper "${repo}" --apply
t_assert_ok cmp -s "${WORK}/signal/config.before" "${repo}/.git/config"
t_assert_fails test -e "${repo}/third_party"

t_case "an incomplete rollback keeps the config backup for recovery"
repo="$(make_consumer cleanup_fail)"
mkdir -p "${WORK}/bin"
cat > "${WORK}/bin/git" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do [ "$arg" != deinit ] || exit 9; done
exec "${REAL_GIT:?}" "$@"
SH
chmod +x "${WORK}/bin/git"
rollback_rc=0
rollback_output="$(REAL_GIT="$(command -v git)" DRIVER_EXIT=7 PATH="${WORK}/bin:${PATH}" \
  run_wrapper "${repo}" --apply 2>&1)" || rollback_rc=$?
t_assert_eq 1 "${rollback_rc}"
t_assert_contains "${rollback_output}" "config backup at "
backup="$(printf '%s\n' "${rollback_output}" | sed -n 's/.*config backup at \([^ ]*\)\..*/\1/p' | tail -n 1)"
t_assert_ok test -f "${backup}"
t_assert_ok cmp -s "${WORK}/cleanup_fail/config.before" "${backup}"

t_case "a failed clone restores the config before a driver can run"
repo="$(make_consumer clone_fail)"
git -C "${repo}" config -f .gitmodules submodule.third_party/ANTfrastructure.url "${WORK}/missing-remote"
git -C "${repo}" add .gitmodules
git -C "${repo}" commit -qm broken-url
cp -p "${repo}/.git/config" "${WORK}/clone_fail/config.before"
t_assert_fails run_wrapper "${repo}" --apply
t_assert_ok cmp -s "${WORK}/clone_fail/config.before" "${repo}/.git/config"
t_assert_fails test -e "${repo}/third_party"
t_assert_fails test -e "${WORK}/clone_fail/driver.args"

t_case "a missing .gitmodules mapping fails before submodule setup"
repo="$(make_consumer missing_mapping)"
git -C "${repo}" config -f .gitmodules --unset submodule.third_party/ANTfrastructure.path
git -C "${repo}" add .gitmodules
git -C "${repo}" commit -qm no-mapping
t_assert_fails run_wrapper "${repo}" --apply
t_assert_fails test -e "${repo}/third_party"
t_assert_ok cmp -s "${WORK}/missing_mapping/config.before" "${repo}/.git/config"
t_assert_fails test -e "${WORK}/missing_mapping/driver.args"

t_case "a preexisting empty hub directory stays after fatal rollback"
repo="$(make_consumer empty_dir)"
mkdir -p "${repo}/third_party/ANTfrastructure"
DRIVER_EXIT=7 t_assert_rc 7 run_wrapper "${repo}" --apply
t_assert_ok test -d "${repo}/third_party/ANTfrastructure"
t_assert_eq "" "$(ls -A "${repo}/third_party/ANTfrastructure")"
t_assert_ok cmp -s "${WORK}/empty_dir/config.before" "${repo}/.git/config"

t_case "a nonempty hub path and an untracked pseudo-gitlink cannot trigger a clone"
repo="$(make_consumer blocked)"
mkdir -p "${repo}/third_party/ANTfrastructure"
printf 'keep\n' > "${repo}/third_party/ANTfrastructure/sentinel"
t_assert_fails run_wrapper "${repo}" --apply
t_assert_eq keep "$(cat "${repo}/third_party/ANTfrastructure/sentinel")"
t_assert_ok cmp -s "${WORK}/blocked/config.before" "${repo}/.git/config"
repo="$(make_consumer missing_gitlink)"
git -C "${repo}" update-index --force-remove -- third_party/ANTfrastructure
git -C "${repo}" commit -qm no-gitlink
t_assert_fails run_wrapper "${repo}" --apply
t_assert_fails test -e "${repo}/third_party"

t_case "a redirected hub path cannot be used as a clone destination"
repo="$(make_consumer symlink)"
if t_posix_symlinks; then
  mkdir -p "${repo}/third_party" "${WORK}/outside"
  ln -s "${WORK}/outside" "${repo}/third_party/ANTfrastructure"
  t_assert_fails run_wrapper "${repo}" --apply
  t_assert_fails test -e "${WORK}/outside/linux/scripts/renovate-local.sh"
  t_assert_ok test -L "${repo}/third_party/ANTfrastructure"
  t_assert_ok cmp -s "${WORK}/symlink/config.before" "${repo}/.git/config"
fi

t_summary
