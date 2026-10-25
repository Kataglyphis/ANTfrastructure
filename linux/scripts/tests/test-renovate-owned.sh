#!/usr/bin/env bash
# GitHub-owned fleet contract: forks, archives, missing checkouts and broken entrypoints must never masquerade as a complete update.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/renovate-fixtures.sh"

FLEET="${TESTS_DIR}/../renovate-fleet.sh"
FAM="${WORK}/family"
BIN="${WORK}/owned-bin"
mkdir -p "${FAM}" "${BIN}"
ln -sf "$(command -v timeout)" "${BIN}/timeout"
OWNED_PATH="${BIN}:${BARE_PATH}"

cat > "${BIN}/gh" <<'GH'
#!/usr/bin/env bash
if [ "$1" = api ] && [ "$2" = user ]; then
  printf '%s\n' "${GH_LOGIN:-fam}"
  exit 0
fi
if [ "$1" = api ] && [ "$2" = --paginate ]; then
  if [ -n "${GH_FAIL:-}" ]; then printf 'fam/hub\n'; exit 9; fi
  case " $* " in
    *'/user/repos?affiliation=owner&visibility=all&per_page=100'*) ;;
    *) exit 9 ;;
  esac
  case " $* " in
    *'select(.fork == false and .archived == false)'*)
      printf 'fam/hub\nfam/consumer\n'
      [ -z "${GH_EXTRA:-}" ] || printf 'fam/%s\n' "${GH_EXTRA}"
      ;;
    *) printf 'fam/hub\nfam/consumer\nfam/fork\nfam/archived\n' ;;
  esac
  exit 0
fi
exit 9
GH
chmod +x "${BIN}/gh"

owned_repo() {
  local name="$1" dir
  dir="$(_init_repo "${FAM}/${name}")"
  git -C "${dir}" remote add origin "https://github.com/fam/${name}.git"
  mkdir -p "${dir}/.github/workflows" "${dir}/scripts/linux"
  printf '{"extends":["github>Kataglyphis/ANTfrastructure"]}\n' > "${dir}/.github/renovate.json"
  printf '#!/usr/bin/env bash\nexec bash "$ANTFRASTRUCTURE_DIR/linux/scripts/renovate-local.sh" "$@"\n' > "${dir}/scripts/linux/renovate-local.sh"
  printf 'on:\n  push:\njobs:\n  renovate:\n    uses: Kataglyphis/ANTfrastructure/.github/workflows/renovate-entrypoint.yml@develop\n' > "${dir}/.github/workflows/renovate-entrypoint.yml"
  printf 'name: fixture\ndependencies:\n  http: 1.1.0\n' > "${dir}/pubspec.yaml"
  _commit "${dir}"
  printf '%s' "${dir}"
}

HUB="$(owned_repo hub)"
CONSUMER="$(owned_repo consumer)"
FORK="$(owned_repo fork)"
ARCHIVED="$(owned_repo archived)"

owned_run() {
  OUT="$(PATH="${OWNED_PATH}" PREFLIGHT_PYTHON="${PY_ABS}" \
    RENOVATE_LOCAL_REPORT="${A_REPORT}" RENOVATE_LOCAL_CONFIG="${CONFIG}" \
    GH_LOGIN="${RUN_LOGIN:-fam}" GH_EXTRA="${RUN_EXTRA:-}" GH_FAIL="${RUN_API_FAIL:-}" \
    bash "${FLEET}" --github-owned --managers pub "$@" "${HUB}" 2>&1)"
  RC=$?
}

t_case "the authenticated, paginated inventory excludes forks and archives"
owned_run
t_assert_eq 0 "${RC}" "the complete active-source report succeeds"
t_assert_contains "${OUT}" "all 2 active, nonfork repositories" "coverage is explicit"
t_assert_contains "${OUT}" "hub" "the hub was read"
t_assert_contains "${OUT}" "consumer" "the consumer was read"
t_assert_fails grep -q '^ *[0-9]*\. *fork ' <<<"${OUT}"
t_assert_fails grep -q '^ *[0-9]*\. *archived ' <<<"${OUT}"
owned_run --checkout-dir "${FAM}"
t_assert_eq 0 "${RC}" "a redundant explicit checkout directory still includes the root"

t_case "a missing own checkout blocks the entire apply before any write"
RUN_EXTRA=missing owned_run --apply
t_assert_eq 1 "${RC}" "the inventory gap is fatal"
t_assert_contains "${OUT}" "github.com/fam/missing" "the missing identity is named"
t_assert_eq '  http: 1.1.0' "$(_pub "${HUB}" 3)" "the first checkout was not written"
t_assert_eq '  http: 1.1.0' "$(_pub "${CONSUMER}" 3)" "nor was the second"

t_case "an incomplete consumer entrypoint blocks the entire apply"
printf '{"extends":[]}\n' > "${CONSUMER}/.github/renovate.json"
owned_run --apply
t_assert_eq 1 "${RC}" "missing shared configuration is fatal"
t_assert_contains "${OUT}" "must extend" "the adoption gap is named"
t_assert_eq '  http: 1.1.0' "$(_pub "${HUB}" 3)" "the hub was not partly updated"
printf '{"extends":["github>Kataglyphis/ANTfrastructure"]}\n' > "${CONSUMER}/.github/renovate.json"

t_case "an authenticated user different from the origin owner is refused"
RUN_LOGIN=elsewhere owned_run --apply
t_assert_eq 1 "${RC}" "wrong account is fatal"
t_assert_contains "${OUT}" "authenticated as elsewhere" "the mismatch is named"

t_case "an API failure after partial output cannot start an apply"
RUN_API_FAIL=1 owned_run --apply
t_assert_eq 1 "${RC}" "a failed inventory is fatal"
t_assert_eq '  http: 1.1.0' "$(_pub "${HUB}" 3)" "no repo ran from a partial inventory"

t_case "one apply invocation delegates to the existing local updater in each eligible repo"
owned_run --apply
t_assert_eq 0 "${RC}" "both local applies succeeded"
t_assert_eq '  http: 1.6.0' "$(_pub "${HUB}" 3)" "hub dependency moved"
t_assert_eq '  http: 1.6.0' "$(_pub "${CONSUMER}" 3)" "consumer dependency moved"
t_assert_eq '  http: 1.1.0' "$(_pub "${FORK}" 3)" "fork was untouched"
t_assert_eq '  http: 1.1.0' "$(_pub "${ARCHIVED}" 3)" "archive was untouched"

t_case "one repo failure reaches the fleet exit code and summary"
_commit "${HUB}"
_commit "${CONSUMER}"
printf 'interrupted\n' > "$(git -C "${CONSUMER}" rev-parse --absolute-git-dir)/renovate-local-inflight"
owned_run --apply
t_assert_eq 1 "${RC}" "the failed member makes the fleet fail"
t_assert_contains "${OUT}" "renovate-local-inflight" "the failing member is explained"
t_assert_contains "${OUT}" "FLEET SUMMARY" "the other result remains visible"

t_case "an explicit checkout directory finds direct children and still includes the root"
rm -f "$(git -C "${CONSUMER}" rev-parse --absolute-git-dir)/renovate-local-inflight"
CHECKOUTS="${WORK}/other-checkouts"
mkdir -p "${CHECKOUTS}/nested"
mv "${CONSUMER}" "${CHECKOUTS}/nested/consumer"
owned_run --checkout-dir "${CHECKOUTS}"
t_assert_eq 1 "${RC}" "a nested checkout is not silently discovered"
t_assert_contains "${OUT}" "github.com/fam/consumer" "the missing direct child is named"
mv "${CHECKOUTS}/nested/consumer" "${CHECKOUTS}/consumer"
CONSUMER="${CHECKOUTS}/consumer"
owned_run --checkout-dir "${CHECKOUTS}"
t_assert_eq 0 "${RC}" "direct children plus the external root cover the inventory"
t_assert_contains "${OUT}" "all 2 active, nonfork repositories" "the complete set is named"

t_case "incompatible options cannot silently narrow the owner inventory"
for option in --here --vendored --only=hub --skip=consumer; do
  owned_run "${option}"
  t_assert_eq 1 "${RC}" "${option} is rejected"
done

t_summary
