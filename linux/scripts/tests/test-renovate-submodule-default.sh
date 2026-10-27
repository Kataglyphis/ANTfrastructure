#!/usr/bin/env bash
# Every direct submodule follows its remote default tip, even across several commits; nested gitlinks are outside this suite.
set -u
# shellcheck source=linux/scripts/tests/renovate-fixtures.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/renovate-fixtures.sh"
source "${TESTS_DIR}/test-uv-fixture.sh"

_default_upstream() {
  local dir="${WORK}/up-$1"
  mkdir -p "${dir}"
  git -C "${dir}" init -q -b trunk
  git -C "${dir}" config protocol.file.allow always
  _plant_file "${dir}" revision.txt "initial $1\n"
  printf '%s' "${dir}"
}

_default_sub_repo() {
  local name="$1" dir first second step
  first="$(_default_upstream "${name}-first")"
  second="$(_default_upstream "${name}-second")"
  git -C "${second}" branch release trunk
  git -C "${second}" switch -q release
  _plant_file "${second}" revision.txt 'release seed\n'
  git -C "${second}" switch -q trunk

  dir="$(_init_repo "${WORK}/${name}")"
  git -C "${dir}" -c protocol.file.allow=always submodule add -q "${first}" first
  git -C "${dir}/first" config protocol.file.allow always
  git -C "${dir}" -c protocol.file.allow=always submodule add -q -b release "${second}" second
  git -C "${dir}/second" config protocol.file.allow always
  git -C "${dir}/second" checkout -q --detach "$(git -C "${second}" rev-parse release)"
  printf 'name: fixture\ndependencies:\n  http: 1.1.0\n' > "${dir}/pubspec.yaml"
  _commit "${dir}"

  for step in 1 2 3; do
    _plant_file "${first}" revision.txt "first trunk ${step}\n"
    _plant_file "${second}" revision.txt "second trunk ${step}\n"
  done
  git -C "${second}" switch -q release
  _plant_file "${second}" revision.txt 'release newer\n'
  git -C "${second}" switch -q trunk
  printf '%s' "${dir}"
}

_absent_second_repo() {
  local repo
  repo="$(_default_sub_repo "$1")"
  _remove_second_checkout "${repo}"
  printf '%s' "${repo}"
}

_remove_second_checkout() {
  local repo="$1"
  git -C "${repo}" submodule --quiet deinit --force -- second
  if [ -d "${repo}/second" ]; then rmdir "${repo}/second"; fi
}

_prepare_rollback_repo() {
  local name="$1" shape="$2"
  if [ "${shape}" = absent ]; then
    ROLLBACK_REPO="$(_absent_second_repo "${name}")"
    ROLLBACK_SECOND_AT=absent
  else
    ROLLBACK_REPO="$(_default_sub_repo "${name}")"
    ROLLBACK_SECOND_AT="$(_module_at "${ROLLBACK_REPO}" second)"
  fi
  ROLLBACK_FIRST_AT="$(_module_at "${ROLLBACK_REPO}" first)"
  ROLLBACK_STATUS="$(git -C "${ROLLBACK_REPO}" status --porcelain=v1 -uall)"
  ROLLBACK_ONCE="${WORK}/${name}-failed-once"
  ROLLBACK_OBSERVED="${WORK}/${name}-first-at-failure"
  ROLLBACK_UP="${WORK}/up-${name}-first"
}

_module_at() {
  printf '%s %s' "$(git -C "$1/$2" rev-parse HEAD)" \
    "$(git -C "$1/$2" symbolic-ref --quiet HEAD || printf 'DETACHED')"
}

_run_checkout_failure() {
  local repo="$1" once="$2" observed="$3"
  local report="${4:-${MIXED_REPORT}}" uv_stubs="${5:-}" uv_observed="${6:-}" managers="${7:-pub,git-submodules}"
  STUB_PATH="${ROLL_STUBS}:${uv_stubs:+${uv_stubs}:}${BARE_PATH}" RL_MODE=checkout RL_REAL_GIT="$(command -v git)" \
    RL_FIRST_PATH="${repo}/first" RL_FAIL_SECOND="${repo}/second" \
    RL_FAIL_ONCE="${once}" RL_OBSERVED_FIRST="${observed}" RL_UV_OBSERVED_DIR="${uv_observed}" \
    _run "${repo}" "${report}" --apply --managers "${managers}"
}

_assert_restored_tree() {
  local repo="$1" first_at="$2" second_at="$3" status_before="$4"
  t_assert_eq "${first_at}" "$(_module_at "${repo}" first)" \
    "the already-moved sibling returns to its commit and ref"
  if [ "${second_at}" = absent ]; then
    t_assert_fails test -e "${repo}/second"
  else
    t_assert_eq "${second_at}" "$(_module_at "${repo}" second)" \
      "the failed checkout stays at its old commit and ref"
  fi
  t_assert_eq '  http: 1.1.0' "$(_pub "${repo}" 3)" "the manifest edit is undone"
  t_assert_eq "${status_before}" "$(git -C "${repo}" status --porcelain=v1 -uall)" \
    "rollback restores the checkout's exact pre-run status"
  t_assert_fails test -f "${repo}/.git/renovate-local-inflight"
}

_assert_checkout_failure_undone() {
  local repo="$1" first_at="$2" second_at="$3" observed="$4" upstream="$5" status_before="$6"
  t_assert_eq 1 "${RC}" "the later checkout failure cannot produce a green run"
  t_assert_ok test -f "${observed}"
  if [ -f "${observed}" ]; then
    t_assert_eq "$(git -C "${upstream}" rev-parse trunk)" "$(cat "${observed}")" \
      "the first checkout reached its new tip before the second failed"
  fi
  _assert_restored_tree "${repo}" "${first_at}" "${second_at}" "${status_before}"
}

_assert_absent_dry_run() {
  local repo="$1" path="$2" tip="$3" report="$4" managers="$5" before
  before="$(git -C "${repo}" status --porcelain=v1 -uall)"
  _run "${repo}" "${report}" --apply --dry-run --managers "${managers}"
  t_assert_eq 0 "${RC}" "the absent checkout has a complete plan: ${OUT}"
  t_assert_contains "${OUT}" "${path}" "the absent submodule path is in the plan"
  t_assert_contains "${OUT}" "${tip}" "the plan names the remote default's exact tip"
  t_assert_fails test -e "${repo}/${path}"
  t_assert_eq "${before}" "$(git -C "${repo}" status --porcelain=v1 -uall)" \
    "dry-run preserves the exact pre-existing absent-path status"
}

_assert_symlink_refusal() {
  local repo="$1" reason="$2" link_path="$3" before_first before_bytes before_link mode
  local -a flags=()
  before_first="$(_module_at "${repo}" first)"
  before_bytes="$(cat "${repo}/first/revision.txt")"
  before_link="$(readlink "${repo}/${link_path}")"
  for mode in report plan apply; do
    case "${mode}" in
      report) flags=() ;;
      plan) flags=(--apply --dry-run) ;;
      apply) flags=(--apply) ;;
    esac
    _run "${repo}" "${MIXED_REPORT}" "${flags[@]}" --managers pub,git-submodules
    t_assert_eq 1 "${RC}" "${mode} refuses a redirected gitlink: ${OUT}"
    t_assert_contains "${OUT}" "${reason}" "${mode} names the redirected path"
    t_assert_eq "${before_first}" "$(_module_at "${repo}" first)" \
      "${mode} never moves the sibling's commit or ref"
    t_assert_eq "${before_bytes}" "$(cat "${repo}/first/revision.txt")" \
      "${mode} never rewrites the sibling's bytes"
    t_assert_ok test -L "${repo}/${link_path}"
    t_assert_eq "${before_link}" "$(readlink "${repo}/${link_path}")" \
      "${mode} preserves the redirected path"
    t_assert_eq '  http: 1.1.0' "$(_pub "${repo}" 3)" "${mode} does not rewrite the manifest"
  done
}

_commit_missing_gitlink() {
  local repo="$1" name="$2" path="$3" url="$4" sha="$5"
  git -C "${repo}" config -f .gitmodules "submodule.${name}.path" "${path}"
  git -C "${repo}" config -f .gitmodules "submodule.${name}.url" "${url}"
  git -C "${repo}" add .gitmodules pubspec.yaml
  git -C "${repo}" update-index --add --cacheinfo "160000,${sha},${path}"
  git -C "${repo}" -c user.email=t@t -c user.name=t commit -qm fixture
}

_relative_sub_repo() {
  local parent="${WORK}/relative-remotes/parent.git"
  local sibling="${WORK}/relative-remotes/sibling.git"
  local source repo initial step
  mkdir -p "${WORK}/relative-remotes"
  git init -q --bare -b trunk "${parent}"
  git init -q --bare -b trunk "${sibling}"
  source="$(_default_upstream relative-source)"
  git -C "${source}" remote add origin "${sibling}"
  git -C "${source}" push -q origin trunk
  initial="$(git -C "${source}" rev-parse trunk)"

  repo="$(_init_repo "${WORK}/relative-consumer")"
  git -C "${repo}" remote add origin "${parent}"
  printf 'name: fixture\ndependencies:\n  http: 1.1.0\n' > "${repo}/pubspec.yaml"
  _commit_missing_gitlink "${repo}" relative/child relative/child ../sibling.git "${initial}"

  for step in 1 2 3; do
    _plant_file "${source}" revision.txt "relative trunk ${step}\n"
  done
  git -C "${source}" push -q origin trunk
  printf '%s' "${repo}"
}

REPORT="${WORK}/default-submodule.json"
_report "${REPORT}" git-submodules .gitmodules first trunk trunk
MIXED_REPORT="${WORK}/default-submodule-mixed.json"
_report_mixed "${MIXED_REPORT}" \
  git-submodules .gitmodules first trunk trunk \
  pub pubspec.yaml http 1.1.0 1.6.0

t_case "the fixture has two sibling gitlinks, only one Renovate row, and three missing default-branch commits"
REPO="$(_default_sub_repo default-dry)"
FIRST_UP="${WORK}/up-default-dry-first"
SECOND_UP="${WORK}/up-default-dry-second"
t_assert_fails git -C "${REPO}" config -f .gitmodules --get submodule.first.branch
t_assert_eq release "$(git -C "${REPO}" config -f .gitmodules --get submodule.second.branch)"
t_assert_eq trunk "$(git -C "${SECOND_UP}" symbolic-ref --short HEAD)"
t_assert_eq 3 "$(git -C "${FIRST_UP}" rev-list --count "$(git -C "${REPO}/first" rev-parse HEAD)"..trunk)"
t_assert_fails test "$(git -C "${SECOND_UP}" rev-parse release)" = "$(git -C "${SECOND_UP}" rev-parse trunk)"
t_assert_fails test "$(git -C "${FIRST_UP}" rev-parse trunk)" = "$(git -C "${SECOND_UP}" rev-parse trunk)"

t_case "dry-run names both direct targets and changes neither checkout nor the manifest"
FIRST_AT="$(_module_at "${REPO}" first)"
SECOND_AT="$(_module_at "${REPO}" second)"
_run "${REPO}" "${REPORT}" --apply --dry-run --managers git-submodules
t_assert_eq 0 "${RC}" "the complete submodule plan is applicable"
t_assert_contains "${OUT}" first "the reported branchless submodule is planned"
t_assert_contains "${OUT}" second "the unreported submodule is planned too"
t_assert_contains "${OUT}" trunk "the plan identifies the remote default branch"
t_assert_contains "${OUT}" "$(git -C "${FIRST_UP}" rev-parse trunk)" "the plan names the first exact target SHA"
t_assert_contains "${OUT}" "$(git -C "${SECOND_UP}" rev-parse trunk)" "the plan names the second exact target SHA"
t_assert_fails grep -q 'REFUSED - behind, but no' <<<"${OUT}"
t_assert_eq "${FIRST_AT}" "$(_module_at "${REPO}" first)" "the first commit and attached ref stay put"
t_assert_eq "${SECOND_AT}" "$(_module_at "${REPO}" second)" "the second commit and ref stay put"
t_assert_eq '  http: 1.1.0' "$(_pub "${REPO}" 3)" "the manifest is untouched"
t_assert_ok git -C "${REPO}" diff --quiet HEAD

t_case "apply reaches each remote default HEAD in one run, not one commit or the declared release branch"
_run "${REPO}" "${REPORT}" --apply --managers git-submodules
t_assert_eq 0 "${RC}" "the complete submodule update succeeds"
t_assert_eq "$(git -C "${FIRST_UP}" rev-parse trunk)" "$(git -C "${REPO}/first" rev-parse HEAD)" \
  "the branchless module skips all three missing commits"
t_assert_eq "$(git -C "${SECOND_UP}" rev-parse trunk)" "$(git -C "${REPO}/second" rev-parse HEAD)" \
  "the unreported module follows its remote default instead of release"
t_assert_fails test "$(git -C "${SECOND_UP}" rev-parse release)" = "$(git -C "${REPO}/second" rev-parse HEAD)"
t_assert_ok git -C "${REPO}" diff --cached --quiet HEAD

t_case "a report with no git-submodules row still updates every initialized direct module"
NO_ROW="$(_default_sub_repo default-no-row)"
PUB_REPORT="${WORK}/default-pub-only.json"
_report "${PUB_REPORT}" pub pubspec.yaml http 1.1.0 1.6.0
_run "${NO_ROW}" "${PUB_REPORT}" --apply --managers pub,git-submodules
t_assert_eq 0 "${RC}" "the manifest and both independent gitlink updates succeed"
t_assert_eq "$(git -C "${WORK}/up-default-no-row-first" rev-parse trunk)" \
  "$(git -C "${NO_ROW}/first" rev-parse HEAD)" "the first unreported module reaches the tip"
t_assert_eq "$(git -C "${WORK}/up-default-no-row-second" rev-parse trunk)" \
  "$(git -C "${NO_ROW}/second" rev-parse HEAD)" "the second unreported module reaches the tip"
t_assert_eq '  http: 1.6.0' "$(_pub "${NO_ROW}" 3)" "the reported manifest also moves"

t_case "dry-run leaves an uninitialized direct module absent; apply initializes it at remote default HEAD"
INIT="$(_absent_second_repo default-init)"
t_assert_fails test -e "${INIT}/second"
INIT_FIRST_AT="$(_module_at "${INIT}" first)"
_assert_absent_dry_run "${INIT}" second "$(git -C "${WORK}/up-default-init-second" rev-parse trunk)" \
  "${REPORT}" git-submodules
t_assert_eq "${INIT_FIRST_AT}" "$(_module_at "${INIT}" first)" "dry-run did not move the initialized sibling"
_run "${INIT}" "${REPORT}" --apply --managers git-submodules
t_assert_eq 0 "${RC}" "apply initializes the missing checkout: ${OUT}"
t_assert_ok test -e "${INIT}/second/.git"
t_assert_eq "$(git -C "${WORK}/up-default-init-first" rev-parse trunk)" \
  "$(git -C "${INIT}/first" rev-parse HEAD)" "the initialized sibling also reaches its default tip"
t_assert_eq "$(git -C "${WORK}/up-default-init-second" rev-parse trunk)" \
  "$(git -C "${INIT}/second" rev-parse HEAD)" "the new checkout reaches its default tip"

t_case "a never-initialized relative URL resolves against parent origin without cloning in dry-run"
REL="$(_relative_sub_repo)"
REL_TIP="$(git -C "${WORK}/up-relative-source" rev-parse trunk)"
t_assert_eq ../sibling.git "$(git -C "${REL}" config -f .gitmodules --get submodule.relative/child.url)"
t_assert_fails test -e "${REL}/relative/child"
t_assert_fails test -e "${REL}/.git/modules/relative/child"
_assert_absent_dry_run "${REL}" relative/child "${REL_TIP}" "${PUB_REPORT}" pub,git-submodules
t_assert_fails test -e "${REL}/.git/modules/relative/child"
t_assert_eq '  http: 1.1.0' "$(_pub "${REL}" 3)" "dry-run leaves the manifest unchanged"
GIT_ALLOW_PROTOCOL="file" _run "${REL}" "${PUB_REPORT}" --apply --managers pub,git-submodules
t_assert_eq 0 "${RC}" "apply initializes through the relative URL: ${OUT}"
t_assert_ok test -e "${REL}/relative/child/.git"
t_assert_eq "${REL_TIP}" "$(git -C "${REL}/relative/child" rev-parse HEAD)" \
  "the checked-out submodule reaches the exact default HEAD"
t_assert_eq '  http: 1.6.0' "$(_pub "${REL}" 3)" "the reported manifest also moves"

t_case "an ignored local file colliding with the new tip is not overwritten and the run rolls back"
COLLISION="$(_default_sub_repo default-collision)"
COLLISION_UP="${WORK}/up-default-collision-second"
printf 'tracked at remote tip\n' > "${COLLISION_UP}/collision.txt"
_commit "${COLLISION_UP}"
COLLISION_GIT="$(git -C "${COLLISION}/second" rev-parse --absolute-git-dir)"
printf 'collision.txt\n' >> "${COLLISION_GIT}/info/exclude"
printf 'keep these local bytes\n' > "${COLLISION}/second/collision.txt"
COLLISION_FIRST_AT="$(_module_at "${COLLISION}" first)"
COLLISION_SECOND_AT="$(_module_at "${COLLISION}" second)"
COLLISION_STATUS="$(git -C "${COLLISION}" status --porcelain=v1 -uall)"
t_assert_eq '' "$(git -C "${COLLISION}/second" status --porcelain=v1 -uall)" \
  "the local collision is ignored by Git, not a dirty tracked file"
t_assert_contains "$(git -C "${COLLISION}/second" status --porcelain=v1 --ignored)" \
  '!! collision.txt' "the collision is present but ignored"
_run "${COLLISION}" "${MIXED_REPORT}" --apply --managers pub,git-submodules
t_assert_eq 1 "${RC}" "the checkout must fail before replacing ignored local bytes: ${OUT}"
t_assert_contains "${OUT}" 'submodule checkout failed for second' "the failed module is named"
t_assert_eq 'keep these local bytes' "$(cat "${COLLISION}/second/collision.txt")" \
  "the ignored file still has its original bytes"
_assert_restored_tree "${COLLISION}" "${COLLISION_FIRST_AT}" "${COLLISION_SECOND_AT}" "${COLLISION_STATUS}"

t_case "a later checkout failure restores the already-moved gitlink, its ref, and a manifest edit"
_prepare_rollback_repo default-rollback initialized
ROLL_STUBS="${WORK}/rollback-stubs"
mkdir -p "${ROLL_STUBS}"
cat > "${ROLL_STUBS}/git" <<'STUB'
#!/usr/bin/env bash
second=0; checkout=0; submodule=0; update=0; initialize=0
for arg in "$@"; do
  case "${arg}" in
    "${RL_FAIL_SECOND}"|second) second=1 ;;
    checkout|switch) checkout=1 ;;
    submodule) submodule=1 ;;
    update) update=1 ;;
    --init) initialize=1 ;;
  esac
done
if [ "${RL_MODE}" = init ] && [ "${submodule}" = 1 ] && [ "${update}" = 1 ] \
    && [ "${initialize}" = 1 ] && [ "${second}" = 1 ]; then
  "${RL_REAL_GIT}" -C "${RL_ROOT}" config submodule.second.url "${RL_REGISTER_URL}" || exit 1
  "${RL_REAL_GIT}" -C "${RL_ROOT}" config --get submodule.second.url > "${RL_REGISTERED}" || exit 1
  "${RL_REAL_GIT}" -C "${RL_FIRST_PATH}" rev-parse HEAD > "${RL_OBSERVED_FIRST}" || exit 1
  exit 42
fi
if [ "${RL_MODE}" = checkout ] && [ "${second}" = 1 ] && [ "${checkout}" = 1 ] \
    && [ ! -e "${RL_FAIL_ONCE}" ]; then
  "${RL_REAL_GIT}" -C "${RL_FIRST_PATH}" rev-parse HEAD > "${RL_OBSERVED_FIRST}" || exit 1
  if [ -n "${RL_UV_OBSERVED_DIR:-}" ]; then
    for path in quality/one/uv.lock quality/two/uv.lock legacy/one.txt legacy/two.txt; do
      mkdir -p "${RL_UV_OBSERVED_DIR}/$(dirname "${path}")"
      cp "${RL_FIRST_PATH}/../${path}" "${RL_UV_OBSERVED_DIR}/${path}" || exit 1
    done
  fi
  : > "${RL_FAIL_ONCE}"
  exit 42
fi
exec "${RL_REAL_GIT}" "$@"
STUB
chmod +x "${ROLL_STUBS}/git"
_run_checkout_failure "${ROLLBACK_REPO}" "${ROLLBACK_ONCE}" "${ROLLBACK_OBSERVED}"
_assert_checkout_failure_undone "${ROLLBACK_REPO}" "${ROLLBACK_FIRST_AT}" "${ROLLBACK_SECOND_AT}" \
  "${ROLLBACK_OBSERVED}" "${ROLLBACK_UP}" "${ROLLBACK_STATUS}"

_uv_sub_repo() {
  local repo project
  repo="$(_default_sub_repo "$1")"
  mkdir -p "${repo}/quality/one" "${repo}/quality/two" "${repo}/legacy" "${repo}/.github"
  for project in one two; do
    printf '[project]\nname = "fixture"\ndependencies = [\n  "demo==1.0",\n]\n' > "${repo}/quality/${project}/pyproject.toml"
    printf 'version = 1\n[[package]]\nname = "demo"\nversion = "1.0"\n' > "${repo}/quality/${project}/uv.lock"
    printf 'fixture==0\n' > "${repo}/legacy/${project}.txt"
  done
  printf '{"exports":[{"project":"quality/one","output":"legacy/one.txt"},{"project":"quality/two","output":"legacy/two.txt"}]}\n' > "${repo}/.github/renovate-uv-exports.json"
  _commit "${repo}"
  printf '%s' "${repo}"
}

_assert_uv_sub_files() {
  local project
  for project in one two; do
    t_assert_contains "$(cat "$1/quality/${project}/uv.lock")" "version = \"$2\""
    t_assert_eq "$3" "$(cat "$1/legacy/${project}.txt")"
  done
}

t_case 'uv updates and direct submodule checkouts succeed together'
UV_MIXED_REPORT="${WORK}/uv-submodule-report.json"
_report_pair "${UV_MIXED_REPORT}" pep621 demo ==1.0 ==2.0 quality/one/pyproject.toml quality/two/pyproject.toml
UV_MIXED_STUBS="${WORK}/uv-submodule-stubs"
t_uv_fixture_write "${UV_MIXED_STUBS}"
UV_SUCCESS="$(_uv_sub_repo uv-submodule-success)"
STUB_PATH="${UV_MIXED_STUBS}:${BARE_PATH}" _run "${UV_SUCCESS}" "${UV_MIXED_REPORT}" --apply --managers pep621,git-submodules
t_assert_eq 0 "${RC}" "combined update succeeds: ${OUT}"
_assert_uv_sub_files "${UV_SUCCESS}" '2.0' 'fixture==1'
t_assert_eq "$(git -C "${WORK}/up-uv-submodule-success-first" rev-parse trunk)" "$(git -C "${UV_SUCCESS}/first" rev-parse HEAD)"
t_assert_eq "$(git -C "${WORK}/up-uv-submodule-success-second" rev-parse trunk)" "$(git -C "${UV_SUCCESS}/second" rev-parse HEAD)"

t_case 'submodule failure rolls back both completed uv exports and locks'
UV_FAIL="$(_uv_sub_repo uv-submodule-failure)"
UV_FAIL_FIRST="$(_module_at "${UV_FAIL}" first)"
UV_FAIL_SECOND="$(_module_at "${UV_FAIL}" second)"
UV_OBSERVED="${WORK}/uv-submodule-observed"
_run_checkout_failure "${UV_FAIL}" "${WORK}/uv-submodule-failed" "${WORK}/uv-submodule-first" \
  "${UV_MIXED_REPORT}" "${UV_MIXED_STUBS}" "${UV_OBSERVED}" pep621,git-submodules
t_assert_eq 1 "${RC}" "late checkout failure cannot pass: ${OUT}"
t_assert_contains "${OUT}" 'submodule checkout failed for second'
t_assert_eq "$(git -C "${WORK}/up-uv-submodule-failure-first" rev-parse trunk)" "$(cat "${WORK}/uv-submodule-first")"
_assert_uv_sub_files "${UV_OBSERVED}" '2.0' 'fixture==1'
_assert_uv_sub_files "${UV_FAIL}" '1.0' 'fixture==0'
t_assert_eq "${UV_FAIL_FIRST}" "$(_module_at "${UV_FAIL}" first)"
t_assert_eq "${UV_FAIL_SECOND}" "$(_module_at "${UV_FAIL}" second)"
t_assert_ok git -C "${UV_FAIL}" diff --quiet HEAD

t_case "rollback removes a checkout initialized by this run after its checkout fails"
_prepare_rollback_repo default-init-rollback absent
_run_checkout_failure "${ROLLBACK_REPO}" "${ROLLBACK_ONCE}" "${ROLLBACK_OBSERVED}"
_assert_checkout_failure_undone "${ROLLBACK_REPO}" "${ROLLBACK_FIRST_AT}" "${ROLLBACK_SECOND_AT}" \
  "${ROLLBACK_OBSERVED}" "${ROLLBACK_UP}" "${ROLLBACK_STATUS}"

t_case "a custom parent-local submodule URL survives an init followed by checkout failure"
_prepare_rollback_repo default-custom-rollback absent
CUSTOM_URL="file://${WORK}/up-default-custom-rollback-second"
git -C "${ROLLBACK_REPO}" config submodule.second.url "${CUSTOM_URL}"
git -C "${ROLLBACK_REPO}" config submodule.second.active true
printf '\n[submodule "second"]\n\t# preserve this owner comment\n' >> "${ROLLBACK_REPO}/.git/config"
CUSTOM_CONFIG_BEFORE="$(git -C "${ROLLBACK_REPO}" config --get-regexp '^submodule\.second\.' | sort)"
CUSTOM_CONFIG_COPY="${WORK}/custom-parent-config-before"
cp "${ROLLBACK_REPO}/.git/config" "${CUSTOM_CONFIG_COPY}"
GIT_ALLOW_PROTOCOL="file" _run_checkout_failure "${ROLLBACK_REPO}" "${ROLLBACK_ONCE}" "${ROLLBACK_OBSERVED}"
_assert_checkout_failure_undone "${ROLLBACK_REPO}" "${ROLLBACK_FIRST_AT}" "${ROLLBACK_SECOND_AT}" \
  "${ROLLBACK_OBSERVED}" "${ROLLBACK_UP}" "${ROLLBACK_STATUS}"
t_assert_eq "${CUSTOM_CONFIG_BEFORE}" \
  "$(git -C "${ROLLBACK_REPO}" config --get-regexp '^submodule\.second\.' | sort)" \
  "rollback restores every pre-existing second-module config entry"
t_assert_eq "${CUSTOM_URL}" "$(git -C "${ROLLBACK_REPO}" config --get submodule.second.url)" \
  "the custom URL remains available for the next run"
t_assert_ok cmp -s "${CUSTOM_CONFIG_COPY}" "${ROLLBACK_REPO}/.git/config"
t_assert_contains "$(cat "${ROLLBACK_REPO}/.git/config")" '# preserve this owner comment' \
  "the rollback keeps the owner's in-section comment"

t_case "an init that registers a parent config URL then fails before checkout removes that new entry"
_prepare_rollback_repo default-early-rollback absent
t_assert_fails git -C "${ROLLBACK_REPO}" config --get submodule.second.url
EARLY_OBSERVED="${WORK}/early-init-first-at-failure"
EARLY_REGISTERED="${WORK}/early-init-registration"
STUB_PATH="${ROLL_STUBS}:${BARE_PATH}" RL_MODE=init RL_REAL_GIT="$(command -v git)" \
  RL_ROOT="${ROLLBACK_REPO}" RL_FIRST_PATH="${ROLLBACK_REPO}/first" \
  RL_FAIL_SECOND="${ROLLBACK_REPO}/second" \
  RL_REGISTER_URL="${WORK}/up-default-early-rollback-second" \
  RL_REGISTERED="${EARLY_REGISTERED}" RL_OBSERVED_FIRST="${EARLY_OBSERVED}" \
  _run "${ROLLBACK_REPO}" "${MIXED_REPORT}" --apply --managers pub,git-submodules
t_assert_eq 1 "${RC}" "a failed init cannot produce a green run"
t_assert_eq "${WORK}/up-default-early-rollback-second" "$(cat "${EARLY_REGISTERED}")" \
  "the stub actually registered a URL before failing"
t_assert_eq "$(git -C "${ROLLBACK_UP}" rev-parse trunk)" \
  "$(cat "${EARLY_OBSERVED}")" "the first module moved before the forced init failure"
_assert_restored_tree "${ROLLBACK_REPO}" "${ROLLBACK_FIRST_AT}" "${ROLLBACK_SECOND_AT}" "${ROLLBACK_STATUS}"
t_assert_fails git -C "${ROLLBACK_REPO}" config --get submodule.second.url

t_case "a missing module alone chooses Windows git only when the checkout reports autocrlf"
# shellcheck source=linux/scripts/renovate-say.sh
source "${TESTS_DIR}/../renovate-say.sh" git-choice-test
# shellcheck source=linux/scripts/renovate-tree.sh
source "${TESTS_DIR}/../renovate-tree.sh"
WIN_CHOICE="$(_absent_second_repo default-win-choice)"
WIN_STUBS="${WORK}/win-choice-stubs"
WIN_LOG="${WORK}/win-choice-git.log"
mkdir -p "${WIN_STUBS}"
t_windows_git_path_stub "${WIN_STUBS}"
cat > "${WIN_STUBS}/git.exe" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${WIN_LOG}"
case " $* " in
  *' rev-parse --git-dir '*) printf '.git\n' ;;
  *' config --get core.autocrlf '*) printf '%s\n' "${WIN_AUTOCRLF}" ;;
  *' diff '*) exit 0 ;;
  *) exit 1 ;;
esac
STUB
chmod +x "${WIN_STUBS}/wslpath" "${WIN_STUBS}/git.exe"
_check_windows_git_choice() {
  local repo="$1" autocrlf="$2" want_bin="$3" want_root="$4" label="$5"
  TARGET="${repo}"
  APPLY_PATHS=(second); EDIT_FILES=()
  : > "${WIN_LOG}"
  PATH="${WIN_STUBS}:${BARE_PATH}" TEST_WIN_ROOT='C:\Fixture\Repo' \
    WIN_AUTOCRLF="${autocrlf}" WIN_LOG="${WIN_LOG}" select_git_for_tree
  t_assert_eq "${want_bin}" "${GIT_BIN}" "${label} selects the owning Git"
  t_assert_eq "${want_root}" "${GIT_TARGET}" "${label} retains its Git path form"
}
_check_windows_git_choice "${WIN_CHOICE}" true git.exe 'C:\Fixture\Repo' 'missing module'
t_assert_contains "$(cat "${WIN_LOG}")" 'config --get core.autocrlf' "ownership was checked"
_check_windows_git_choice "${WIN_CHOICE}" false git "${WIN_CHOICE}" 'Linux-owned checkout'

t_case "an initialized-only hub still uses Windows Git when autocrlf owns the checkout"
WIN_INITIAL="$(_default_sub_repo default-win-initialized)"
_check_windows_git_choice "${WIN_INITIAL}" true git.exe 'C:\Fixture\Repo' 'initialized module'
t_assert_contains "$(cat "${WIN_LOG}")" 'config --get core.autocrlf' "the choice checks ownership without a missing module"

t_case "a proven EOL-only path keeps the Windows Git fallback without autocrlf"
printf 'name: fixture\r\ndependencies:\r\n  http: 1.1.0\r\n' > "${WIN_INITIAL}/pubspec.yaml"
TARGET="${WIN_INITIAL}"
APPLY_PATHS=(); EDIT_FILES=(pubspec.yaml)
PATH="${WIN_STUBS}:${BARE_PATH}" TEST_WIN_ROOT='C:\Fixture\Repo' WIN_AUTOCRLF="false" WIN_LOG="${WIN_LOG}" select_git_for_tree
t_assert_eq git.exe "${GIT_BIN}" "EOL evidence still selects the Windows Git checkout"

t_case "an initialized gitlink symlinked to a sibling is refused before any update"
LINKED="$(_default_sub_repo default-linked)"
_remove_second_checkout "${LINKED}"
ln -s first "${LINKED}/second"
t_assert_ok test -L "${LINKED}/second"
_assert_symlink_refusal "${LINKED}" 'submodule second is a symlink' second

t_case "an absent nested gitlink beneath an inside-root symlinked parent is refused"
PARENT_LINK="$(_default_sub_repo default-parent-link)"
PARENT_INITIAL="$(git -C "${PARENT_LINK}/first" rev-parse HEAD)"
_commit_missing_gitlink "${PARENT_LINK}" nested/child nested/child \
  "${WORK}/up-default-parent-link-first" "${PARENT_INITIAL}"
mkdir -p "${PARENT_LINK}/inside"
ln -s inside "${PARENT_LINK}/nested"
t_assert_ok test -L "${PARENT_LINK}/nested"
t_assert_fails test -e "${PARENT_LINK}/nested/child"
_assert_symlink_refusal "${PARENT_LINK}" \
  'uninitialized submodule nested/child resolves away from its tracked path' nested

t_summary
