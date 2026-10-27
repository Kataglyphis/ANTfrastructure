#!/usr/bin/env bash
# Tests transactional uv exports with stubs; real package resolution and GitHub are outside this fixture.
set -u
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/renovate-fixtures.sh"
UV_STUBS="${WORK}/uv-export-stubs"
mkdir -p "${UV_STUBS}"
cat > "${UV_STUBS}/uv" <<'STUB'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${UV_EXPORT_TEST_LOG}"
case "$1" in
  lock)
    [ "${UV_WORKING_DIR+x}" = '' ] || exit 10
    [ "${UV_EXPORT_TEST_FAIL_LOCK:-0}" = 0 ] || exit 11
    printf 'version = 1\n[[package]]\nname = "demo"\nversion = "2.0"\n' > uv.lock ;;
  export)
    [ "${UV_NO_GROUP+x}${UV_NO_DEFAULT_GROUPS+x}${UV_NO_DEV+x}${UV_WORKING_DIR+x}" = '' ] || exit 10
    [ "${UV_EXPORT_TEST_FAIL:-0}" = 0 ] || exit 7
    case " $* " in *" --project ${UV_EXPORT_TEST_FAIL_PROJECT:-<none>} "*) exit 7 ;; esac
    while [ "$#" -gt 0 ]; do
      if [ "$1" = --output-file ]; then printf 'demo==2.0\n' > "$2"; exit 0; fi
      shift
    done
    exit 8 ;;
  *) exit 9 ;;
esac
STUB
chmod +x "${UV_STUBS}/uv"
export UV_EXPORT_TEST_LOG="${WORK}/uv-export.log"
# shellcheck disable=SC2034
STUB_PATH="${UV_STUBS}:${BARE_PATH}"
_export_repo() {
  local d
  d="$(_repo "$1")"
  mkdir -p "${d}/quality/tool" "${d}/legacy"
  printf '[project]\nname = "fixture"\ndependencies = [\n  "demo==1.0",\n]\n' > "${d}/quality/tool/pyproject.toml"
  printf 'version = 1\n[[package]]\nname = "demo"\nversion = "1.0"\n' > "${d}/quality/tool/uv.lock"
  printf 'demo==1.0\n' > "${d}/legacy/requirements.txt"
  printf '{"exports":[{"project":"quality/tool","output":"legacy/requirements.txt"}]}\n' > "${d}/.github/renovate-uv-exports.json"
  _commit "${d}"
  printf '%s' "${d}"
}
REPORT="${WORK}/uv-export-report.json"
_report "${REPORT}" pep621 quality/tool/pyproject.toml demo ==1.0 ==2.0
_run_failed() {
  _run "$1" "${REPORT}" --apply --managers pep621
  t_assert_eq 1 "${RC}" "$2: ${OUT}"
}
_change_and_refuse() {
  printf '%s\n' "$3" > "$1/$2"
  _run_failed "$1" "$4"
}
_plant_other_project() {
  mkdir -p "$1/quality/other"
  cp "$1/quality/tool/pyproject.toml" "$1/quality/other/pyproject.toml"
  cp "$1/quality/tool/uv.lock" "$1/quality/other/uv.lock"
  printf 'demo==1.0\n' > "$1/legacy/other.txt"
}
_assert_export_rollback() {
  _run "$1" "$2" --apply --managers pep621
  t_assert_eq 1 "${RC}" "failed export must fail: ${OUT}"
  t_assert_contains "${OUT}" 'uv compatibility export failed'
  t_assert_ok git -C "$1" diff --quiet HEAD
  t_assert_eq 'demo==1.0' "$(cat "$1/legacy/requirements.txt")"
}
_assert_invalid_mapping() {
  printf '%s\n' "$2" > "$1/.github/renovate-uv-exports.json"
  _commit "$1"
  _run_failed "$1" 'invalid mapping refuses apply'
  t_assert_contains "${OUT}" "$3"
  t_assert_ok git -C "$1" diff --quiet HEAD
}
_assert_export_updated() { t_assert_eq 'demo==2.0' "$(cat "$1/legacy/requirements.txt")"; }

t_case 'dry-run lists the compatibility export without writing or invoking uv'
dry="$(_export_repo dry)"; : > "${UV_EXPORT_TEST_LOG}"
_run "${dry}" "${REPORT}" --apply --dry-run --managers pep621
t_assert_eq 0 "${RC}" "dry-run succeeds: ${OUT}"
t_assert_contains "${OUT}" 'legacy/requirements.txt' "the reviewed plan names the generated file"
t_assert_eq '' "$(cat "${UV_EXPORT_TEST_LOG}")" "dry-run never invokes uv"
t_assert_ok git -C "${dry}" diff --quiet HEAD

t_case 'apply refreshes lock and generated requirements as one unit'
good="$(_export_repo good)"; : > "${UV_EXPORT_TEST_LOG}"
_run "${good}" "${REPORT}" --apply --managers pep621
t_assert_eq 0 "${RC}" "apply succeeds: ${OUT}"
t_assert_contains "$(cat "${good}/quality/tool/pyproject.toml")" 'demo==2.0'
t_assert_contains "$(cat "${good}/quality/tool/uv.lock")" 'version = "2.0"'
t_assert_eq 'demo==2.0' "$(cat "${good}/legacy/requirements.txt")"
t_assert_contains "$(cat "${UV_EXPORT_TEST_LOG}")" '--locked --no-dev --no-default-groups --no-emit-project --no-header --no-annotate --format requirements-txt'

t_case 'ambient uv group and working-directory overrides cannot alter the export'
poisoned="$(_export_repo poisoned)"
UV_NO_GROUP=docs UV_NO_DEFAULT_GROUPS=1 UV_NO_DEV=1 UV_WORKING_DIR=/missing _run "${poisoned}" "${REPORT}" --apply --managers pep621
t_assert_eq 0 "${RC}" "poisoned environment is isolated: ${OUT}"
_assert_export_updated "${poisoned}"

t_case 'a failed uv lock still rolls back with a poisoned working-directory override'
lock_failure="$(_export_repo lock-failure)"
UV_WORKING_DIR=/missing UV_EXPORT_TEST_FAIL_LOCK=1 _run "${lock_failure}" "${REPORT}" --apply --managers pep621
t_assert_eq 1 "${RC}" "a failed lock must fail: ${OUT}"
t_assert_ok git -C "${lock_failure}" diff --quiet HEAD
t_assert_eq 'demo==1.0' "$(cat "${lock_failure}/legacy/requirements.txt")"

t_case 'a locally changed generated file blocks the whole update'
dirty="$(_export_repo dirty)"
_change_and_refuse "${dirty}" legacy/requirements.txt 'local work' 'dirty output refuses apply'
t_assert_contains "${OUT}" 'legacy/requirements.txt'
t_assert_contains "$(cat "${dirty}/quality/tool/pyproject.toml")" 'demo==1.0'
t_assert_eq 'local work' "$(cat "${dirty}/legacy/requirements.txt")"

t_case 'an export failure restores manifest, lock and legacy bytes'
failed="$(_export_repo failed)"
UV_EXPORT_TEST_FAIL=1 _assert_export_rollback "${failed}" "${REPORT}"

t_case 'failure in the second export rolls back both projects and the first export'
dual="$(_export_repo dual)"
_plant_other_project "${dual}"
printf '{"exports":[{"project":"quality/tool","output":"legacy/requirements.txt"},{"project":"quality/other","output":"legacy/other.txt"}]}\n' > "${dual}/.github/renovate-uv-exports.json"
_commit "${dual}"
_report_pair "${WORK}/uv-export-dual.json" pep621 demo ==1.0 ==2.0 quality/tool/pyproject.toml quality/other/pyproject.toml
UV_EXPORT_TEST_FAIL_PROJECT=quality/other _assert_export_rollback "${dual}" "${WORK}/uv-export-dual.json"
t_assert_eq 'demo==1.0' "$(cat "${dual}/legacy/other.txt")"

t_case 'lock maintenance also refreshes its declared compatibility export'
maint="$(_export_repo maint)"
MAINT_CONFIG="${WORK}/uv-export-maint.json"
sed 's|"packageRules":\[\]|"lockFileMaintenance":{"enabled":true},"packageRules":[]|' "${CONFIG}" > "${MAINT_CONFIG}"
printf '{"repositories":{"local":{"packageFiles":{"pep621":[{"packageFile":"quality/tool/pyproject.toml","deps":[]}]}}}}\n' > "${WORK}/uv-export-maint-report.json"
RUN_CONFIG="${MAINT_CONFIG}" _run "${maint}" "${WORK}/uv-export-maint-report.json" --apply --managers pep621
t_assert_eq 0 "${RC}" "lock maintenance succeeds: ${OUT}"
_assert_export_updated "${maint}"

t_case 'a separate manager cannot independently edit a derived output'
conflict="$(_export_repo conflict)"
_report_mixed "${WORK}/uv-export-conflict.json" \
  pep621 quality/tool/pyproject.toml demo ==1.0 ==2.0 \
  pip_requirements legacy/requirements.txt demo ==1.0 ==2.0
_run "${conflict}" "${WORK}/uv-export-conflict.json" --apply --managers pep621,pip_requirements
t_assert_eq 1 "${RC}" "independent edits are refused: ${OUT}"
t_assert_contains "${OUT}" 'independent planned edit'
t_assert_ok git -C "${conflict}" diff --quiet HEAD

t_case 'local changes to the export configuration block apply'
config_dirty="$(_export_repo config-dirty)"
printf ' ' >> "${config_dirty}/.github/renovate-uv-exports.json"
_run_failed "${config_dirty}" 'dirty configuration refuses apply'
t_assert_contains "${OUT}" 'configuration has local changes'
t_assert_eq 'demo==1.0' "$(cat "${config_dirty}/legacy/requirements.txt")"

t_case 'a removed tracked configuration blocks the update'
config_removed="$(_export_repo config-removed)"
rm "${config_removed}/.github/renovate-uv-exports.json"
_run_failed "${config_removed}" 'removed configuration refuses apply'
t_assert_contains "${OUT}" 'configuration has local changes'
t_assert_contains "$(cat "${config_removed}/quality/tool/pyproject.toml")" 'demo==1.0'

t_case 'a locally emptied configuration blocks the update'
config_empty="$(_export_repo config-empty)"
_change_and_refuse "${config_empty}" .github/renovate-uv-exports.json '{"exports":[]}' 'empty changed configuration refuses apply'
t_assert_contains "${OUT}" 'configuration has local changes'
t_assert_contains "$(cat "${config_empty}/quality/tool/pyproject.toml")" 'demo==1.0'

t_case 'an untracked empty configuration blocks the update'
config_untracked="$(_export_repo config-untracked)"
git -C "${config_untracked}" rm --cached -q .github/renovate-uv-exports.json
git -C "${config_untracked}" -c user.email=t@t -c user.name=t commit -qm 'untrack export configuration'
printf '{"exports":[]}\n' > "${config_untracked}/.github/renovate-uv-exports.json"
_run_failed "${config_untracked}" 'untracked configuration refuses apply'
t_assert_contains "${OUT}" 'not tracked'
t_assert_contains "$(cat "${config_untracked}/quality/tool/pyproject.toml")" 'demo==1.0'

t_case 'an untracked output cannot enter the transaction'
untracked="$(_export_repo untracked)"
git -C "${untracked}" rm --cached -q legacy/requirements.txt
git -C "${untracked}" -c user.email=t@t -c user.name=t commit -qm 'untrack export'
_run_failed "${untracked}" 'the target is not tracked'
t_assert_contains "${OUT}" 'not tracked'

t_case 'a redirected output outside the repository is refused before changes'
unsafe="$(_export_repo unsafe)"
_assert_invalid_mapping "${unsafe}" '{"exports":[{"project":"quality/tool","output":"../outside"}]}' 'invalid uv export configuration'

t_case 'a symlinked output is refused before changes'
redirected="$(_export_repo redirected)"
rm "${redirected}/legacy/requirements.txt"
printf 'outside\n' > "${WORK}/outside"
ln -s "${WORK}/outside" "${redirected}/legacy/requirements.txt"
_commit "${redirected}"
_run_failed "${redirected}" 'redirected output refuses apply'
t_assert_contains "${OUT}" 'invalid uv export configuration'
t_assert_eq 'outside' "$(cat "${WORK}/outside")"

t_case 'a symlink within the repository is not a safe output either'
inside="$(_export_repo inside)"
printf 'other\n' > "${inside}/legacy/other.txt"
rm "${inside}/legacy/requirements.txt"
ln -s other.txt "${inside}/legacy/requirements.txt"
_commit "${inside}"
_run_failed "${inside}" 'an internal symlink refuses apply'
t_assert_contains "${OUT}" 'invalid uv export configuration'
t_assert_eq 'other' "$(cat "${inside}/legacy/other.txt")"

t_case 'an output through a symlinked directory is refused before changes'
aliased="$(_export_repo aliased)"
ln -s legacy "${aliased}/alias"
_assert_invalid_mapping "${aliased}" '{"exports":[{"project":"quality/tool","output":"alias/requirements.txt"}]}' 'invalid uv export configuration'
t_assert_eq 'demo==1.0' "$(cat "${aliased}/legacy/requirements.txt")"

t_case 'one export cannot overwrite another configured project lock'
overlap="$(_export_repo overlap)"
_plant_other_project "${overlap}"
_assert_invalid_mapping "${overlap}" '{"exports":[{"project":"quality/tool","output":"quality/other/uv.lock"},{"project":"quality/other","output":"legacy/other.txt"}]}' 'output overlaps a configured input'

t_summary
