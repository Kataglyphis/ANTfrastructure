#!/usr/bin/env bash
# The copied wrapper bootstraps only a real apply; live Renovate and a Windows container are outside this fixture.
set -u
# shellcheck source=linux/scripts/tests/renovate-bootstrap-fixture.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/renovate-bootstrap-fixture.sh"
TEMPLATES="$(cd "${_T_SCRIPTS}/../../shared/linux/templates" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

_bootstrap_seed() {
  local seed="$1"
  t_renovate_bootstrap_driver "${seed}" <<'SH' || return 1
#!/usr/bin/env bash
printf '%s\n' "$@" > "${DRIVER_ARGS:?}"
if [ "${DRIVER_SIGNAL:-0}" = 1 ]; then kill -TERM "$PPID"; fi
exit "${DRIVER_EXIT:-0}"
SH
  printf '[submodule "nested"]\n\tpath = nested\n\turl = /missing/nested\n' > "${seed}/.gitmodules" || return 1
  git -C "${seed}" update-index --add --cacheinfo "160000,1111111111111111111111111111111111111111,nested"
}

_bootstrap_consumer() {
  local repo="$1"
  mkdir -p "${repo}/scripts/linux/lib" || return 1
  cp "${TEMPLATES}/renovate-local.sh" "${repo}/scripts/linux/renovate-local.sh" || return 1
  cp "${TEMPLATES}/antfrastructure.sh" "${repo}/scripts/linux/lib/antfrastructure.sh" || return 1
  cp "${TEMPLATES}/renovate-git-mode.sh" "${repo}/scripts/linux/lib/renovate-git-mode.sh"
}

make_consumer() { t_renovate_bootstrap_fixture "${WORK}/$1" _bootstrap_seed _bootstrap_consumer; }

run_wrapper() {
  local repo="$1"
  shift
  t_renovate_bootstrap_run "${repo}" "${WORK}" "$@"
}

run_windows_wrapper() {
  local repo="$1" scenario="$2"
  shift 2
  WIN_GIT_ROOT="${repo}" WIN_GIT_LOG="${WORK}/${scenario}/git.log" \
    TEST_WIN_ROOT='C:\Fixture' TEST_WIN_CONFIG='C:/Fixture/.git/config' \
    TEST_WSL_CONFIG="${repo}/.git/config" REAL_GIT="$(command -v git)" \
    PATH="${WORK}/win-git-bin:${PATH}" run_wrapper "${repo}" "$@"
}

t_case "a copied bootstrap stays within the consumer complexity limit"
repo="$(make_consumer complexity)" || exit 1
t_assert_rc 0 python3 "${_T_SCRIPTS}/verify_code_complexity.py" --root "${repo}"
printf '\nantfrastructure_complexity_mutant() {\n' >> "${repo}/scripts/linux/lib/antfrastructure.sh"
for branch in {1..16}; do
  printf '  if [ %s -gt 0 ]; then :; fi\n' "$branch" >> "${repo}/scripts/linux/lib/antfrastructure.sh"
done
printf '}\n' >> "${repo}/scripts/linux/lib/antfrastructure.sh"
complexity_rc=0
complexity_output="$(python3 "${_T_SCRIPTS}/verify_code_complexity.py" --root "${repo}" 2>&1)" || complexity_rc=$?
t_assert_eq 1 "${complexity_rc}"
t_assert_contains "${complexity_output}" "antfrastructure_complexity_mutant:cc"

t_case "a copied bootstrap has no trailing conditional return"
repo="$(make_consumer trailing_conditional)" || exit 1
t_assert_rc 0 python3 "${_T_SCRIPTS}/verify_trailing_conditional.py" --root "${repo}"
cat >> "${repo}/scripts/linux/lib/antfrastructure.sh" <<'SH'
antfrastructure_trailing_mutant() {
  [ "${1:-}" = yes ]
}
SH
trailing_rc=0
trailing_output="$(python3 "${_T_SCRIPTS}/verify_trailing_conditional.py" --root "${repo}" 2>&1)" || trailing_rc=$?
t_assert_eq 1 "${trailing_rc}"
t_assert_contains "${trailing_output}" "antfrastructure_trailing_mutant"

t_case "report and dry-run refuse an unavailable hub without cloning it"
repo="$(make_consumer read_only)" || exit 1
t_assert_fails run_wrapper "${repo}"
t_assert_fails run_wrapper "${repo}" --apply --dry-run
t_renovate_bootstrap_assert_pristine "${repo}"

t_case "a missing copied Git mode companion fails before hub initialization"
repo="$(make_consumer missing_git_mode)" || exit 1
rm "${repo}/scripts/linux/lib/renovate-git-mode.sh"
missing_mode_rc=0
missing_mode_output="$(run_wrapper "${repo}" --apply 2>&1)" || missing_mode_rc=$?
t_assert_eq 1 "${missing_mode_rc}"
t_assert_contains "${missing_mode_output}" "Renovate Git mode companion missing"
t_assert_fails test -e "${repo}/third_party"
t_assert_ok cmp -s "${WORK}/missing_git_mode/config.before" "${repo}/.git/config"

t_case "an initialized old hub reports its missing driver without bootstrap"
repo="$(make_consumer old_pin)" || exit 1
env GIT_ALLOW_PROTOCOL=file git -C "${repo}" submodule update --init -- third_party/ANTfrastructure >/dev/null 2>&1
rm "${repo}/third_party/ANTfrastructure/linux/scripts/renovate-local.sh"
old_pin_rc=0
old_pin_output="$(run_wrapper "${repo}" --apply 2>&1)" || old_pin_rc=$?
t_assert_eq 1 "${old_pin_rc}"
t_assert_contains "${old_pin_output}" "ANTfrastructure file not found"
t_assert_ok test -e "${repo}/third_party/ANTfrastructure/.git"

t_case "apply initializes only the direct hub before invoking the driver"
repo="$(make_consumer apply)" || exit 1
t_assert_rc 0 run_wrapper "${repo}" --apply --managers pub
t_assert_eq "${repo}" "$(sed -n '1p' "${WORK}/apply/driver.args")"
t_assert_eq --apply "$(sed -n '2p' "${WORK}/apply/driver.args")"
t_assert_eq "$(git -C "${repo}" rev-parse HEAD:third_party/ANTfrastructure)" \
  "$(git -C "${repo}/third_party/ANTfrastructure" rev-parse HEAD)"
t_assert_fails test -e "${repo}/third_party/ANTfrastructure/nested/.git"
t_assert_eq "" "$(git -C "${repo}" status --porcelain)"

t_case "a Windows Git checkout uses its own index view for bootstrap and rollback"
t_windows_git_path_stub "${WORK}/win-git-bin"
cat > "${WORK}/win-git-bin/git.exe" <<'SH'
#!/usr/bin/env bash
[ "$1" = -C ] && [ "$2" = 'C:\Fixture' ] || exit 2
shift 2
printf '%s\n' "$*" >> "${WIN_GIT_LOG:?}"
if [ "$1" = config ] && [ "$2" = --get ] && [ "$3" = core.autocrlf ]; then
  printf '%s\n' "${WIN_AUTOCRLF:-true}"
  exit 0
fi
if [ "$1" = rev-parse ] && [ "$2" = --path-format=absolute ] &&
   [ "$3" = --git-path ] && [ "$4" = config ]; then
  printf 'C:/Fixture/.git/config\n'
  exit 0
fi
exec "${REAL_GIT:?}" -C "${WIN_GIT_ROOT:?}" "$@"
SH
cat > "${WORK}/win-git-bin/git" <<'SH'
#!/usr/bin/env bash
if [ "$1" = -C ] && [ "$2" = "${WIN_GIT_ROOT:-}" ] &&
   [ "${3:-}" = diff ] && [ "${4:-}" = --quiet ] && [ "${5:-}" = -- ] &&
   [ "${6:-}" = .gitmodules ]; then
  exit 1
fi
exec "${REAL_GIT:?}" "$@"
SH
chmod +x "${WORK}/win-git-bin/"*
repo="$(make_consumer win_git_apply)" || exit 1
t_assert_rc 0 run_windows_wrapper "${repo}" win_git_apply --apply
t_assert_ok test -e "${repo}/third_party/ANTfrastructure/.git"
t_assert_contains "$(cat "${WORK}/win_git_apply/git.log")" "diff --quiet -- .gitmodules"
t_assert_contains "$(cat "${WORK}/win_git_apply/git.log")" "rev-parse --path-format=absolute --git-path config"
t_assert_contains "$(cat "${WORK}/win_git_apply/git.log")" "submodule update --init -- third_party/ANTfrastructure"
repo="$(make_consumer win_git_fatal)" || exit 1
DRIVER_EXIT=7 t_assert_rc 7 run_windows_wrapper "${repo}" win_git_fatal --apply
t_assert_contains "$(cat "${WORK}/win_git_fatal/git.log")" "submodule deinit --force -- third_party/ANTfrastructure"
t_assert_ok cmp -s "${WORK}/win_git_fatal/config.before" "${repo}/.git/config"
t_assert_fails test -e "${repo}/third_party"

t_case "a Linux-owned WSL checkout is not claimed by Windows Git"
repo="$(make_consumer win_git_false)" || exit 1
WIN_AUTOCRLF=false t_assert_rc 1 run_windows_wrapper "${repo}" win_git_false --apply
t_assert_contains "$(cat "${WORK}/win_git_false/git.log")" "config --get core.autocrlf"
t_assert_fails test -e "${repo}/third_party"
t_assert_ok cmp -s "${WORK}/win_git_false/config.before" "${repo}/.git/config"
t_assert_fails test -e "${WORK}/win_git_false/driver.args"

t_case "a driver refusal exits two and keeps its initialized hub for review"
repo="$(make_consumer refused)" || exit 1
DRIVER_EXIT=2 t_assert_rc 2 run_wrapper "${repo}" --apply
t_assert_ok test -f "${repo}/third_party/ANTfrastructure/linux/scripts/renovate-local.sh"

t_case "a fatal driver status restores the config and originally absent directories"
repo="$(make_consumer fatal)" || exit 1
DRIVER_EXIT=7 t_assert_rc 7 run_wrapper "${repo}" --apply
t_assert_ok cmp -s "${WORK}/fatal/config.before" "${repo}/.git/config"
t_assert_fails test -e "${repo}/third_party"
t_assert_eq "$(git -C "${repo}" rev-parse HEAD:third_party/ANTfrastructure)" \
  "$(git -C "${repo}" ls-files --stage -- third_party/ANTfrastructure | cut -d' ' -f2)"

t_case "a signal after bootstrap restores the initially missing hub"
repo="$(make_consumer signal)" || exit 1
DRIVER_SIGNAL=1 t_assert_rc 143 run_wrapper "${repo}" --apply
t_assert_ok cmp -s "${WORK}/signal/config.before" "${repo}/.git/config"
t_assert_fails test -e "${repo}/third_party"

t_case "an incomplete rollback keeps the config backup for recovery"
repo="$(make_consumer cleanup_fail)" || exit 1
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
repo="$(make_consumer clone_fail)" || exit 1
git -C "${repo}" config -f .gitmodules submodule.third_party/ANTfrastructure.url "${WORK}/missing-remote"
git -C "${repo}" add .gitmodules
git -C "${repo}" commit -qm broken-url
cp -p "${repo}/.git/config" "${WORK}/clone_fail/config.before"
t_assert_fails run_wrapper "${repo}" --apply
t_assert_ok cmp -s "${WORK}/clone_fail/config.before" "${repo}/.git/config"
t_assert_fails test -e "${repo}/third_party"
t_assert_fails test -e "${WORK}/clone_fail/driver.args"

t_case "a missing .gitmodules mapping fails before submodule setup"
repo="$(make_consumer missing_mapping)" || exit 1
git -C "${repo}" config -f .gitmodules --unset submodule.third_party/ANTfrastructure.path
git -C "${repo}" add .gitmodules
git -C "${repo}" commit -qm no-mapping
t_assert_fails run_wrapper "${repo}" --apply
t_assert_fails test -e "${repo}/third_party"
t_assert_ok cmp -s "${WORK}/missing_mapping/config.before" "${repo}/.git/config"
t_assert_fails test -e "${WORK}/missing_mapping/driver.args"

t_case "a preexisting empty hub directory stays after fatal rollback"
repo="$(make_consumer empty_dir)" || exit 1
mkdir -p "${repo}/third_party/ANTfrastructure"
DRIVER_EXIT=7 t_assert_rc 7 run_wrapper "${repo}" --apply
t_assert_ok test -d "${repo}/third_party/ANTfrastructure"
t_assert_eq "" "$(ls -A "${repo}/third_party/ANTfrastructure")"
t_assert_ok cmp -s "${WORK}/empty_dir/config.before" "${repo}/.git/config"

t_case "a nonempty hub path and an untracked pseudo-gitlink cannot trigger a clone"
repo="$(make_consumer blocked)" || exit 1
mkdir -p "${repo}/third_party/ANTfrastructure"
printf 'keep\n' > "${repo}/third_party/ANTfrastructure/sentinel"
t_assert_fails run_wrapper "${repo}" --apply
t_assert_eq keep "$(cat "${repo}/third_party/ANTfrastructure/sentinel")"
t_assert_ok cmp -s "${WORK}/blocked/config.before" "${repo}/.git/config"
repo="$(make_consumer missing_gitlink)" || exit 1
git -C "${repo}" update-index --force-remove -- third_party/ANTfrastructure
git -C "${repo}" commit -qm no-gitlink
t_assert_fails run_wrapper "${repo}" --apply
t_assert_fails test -e "${repo}/third_party"

t_case "a redirected hub path cannot be used as a clone destination"
repo="$(make_consumer symlink)" || exit 1
if t_posix_symlinks; then
  mkdir -p "${repo}/third_party" "${WORK}/outside"
  ln -s "${WORK}/outside" "${repo}/third_party/ANTfrastructure"
  t_assert_fails run_wrapper "${repo}" --apply
  t_assert_fails test -e "${WORK}/outside/linux/scripts/renovate-local.sh"
  t_assert_ok test -L "${repo}/third_party/ANTfrastructure"
  t_assert_ok cmp -s "${WORK}/symlink/config.before" "${repo}/.git/config"
fi

t_summary
