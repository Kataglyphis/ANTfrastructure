#!/usr/bin/env bash
# Lock file maintenance: Renovate builds it but never reports it locally, so renovate-local.sh carries it. See docs/dependency-updates.md#lock-file-maintenance
set -u
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/renovate-fixtures.sh"

# The fixture config with the preset's block spliced in front of its empty packageRules.
MAINT_CFG="${WORK}/maint.json"
sed 's|"packageRules":\[\]|"lockFileMaintenance":{"enabled":true,"schedule":["at any time"]},"packageRules":[]|' \
  "${CONFIG}" > "${MAINT_CFG}"
RULE_OFF_CFG="${WORK}/maint-rule-off.json"
sed 's|"packageRules":\[\]|"lockFileMaintenance":{"enabled":true},"packageRules":[{"matchManagers":["pep621"],"enabled":false}]|' \
  "${CONFIG}" > "${RULE_OFF_CFG}"
t_case "the spliced configs carry the block, so a green run below is not a no-op"
t_assert_contains "$(cat "${MAINT_CFG}")" '"lockFileMaintenance":{"enabled":true' "maint.json"
t_assert_contains "$(cat "${RULE_OFF_CFG}")" '"enabled":false}]' "maint-rule-off.json"

# _lock_report <out> <manager> <file>...: package files with nothing behind, the shape a fully pinned repo reports.
_lock_report() {
  local out="$1" mgr="$2" sep="" f body=""
  shift 2
  for f in "$@"; do
    body="${body}${sep}{\"packageFile\":\"${f}\",\"deps\":[]}"
    sep=,
  done
  printf '{"repositories":{"local":{"packageFiles":{"%s":[%s]}}}}\n' "${mgr}" "${body}" > "${out}"
}

# _maint <config> <repo> <report> <args...>: one stubbed run from an empty argv log; ARGV holds what ran.
ARGV=""
_maint() {
  local cfg="$1"
  shift
  : > "${ARGV_LOG}"
  RUN_CONFIG="${cfg}" _run_stubbed "$@"
  ARGV="$(cat "${ARGV_LOG}")"
}

PEP_REPORT="${WORK}/pep-maint.json"
_lock_report "${PEP_REPORT}" pep621 pyproject.toml
PEP_TOML='[project]\nname = "fixture"\ndependencies = [\n  "ruff==0.9.0",\n]\n'
M1="$(_plant_all m1 pyproject.toml "${PEP_TOML}" uv.lock '# placeholder\n')"

t_case "(M1) report: a maintained lock is listed with its upgrade command, and only its dry run runs"
_maint "${MAINT_CFG}" "${M1}" "${PEP_REPORT}" --managers pep621
t_assert_eq "0" "${RC}" "a report exits 0"
t_assert_contains "${OUT}" "LOCK FILE MAINTENANCE" "the report has the section"
t_assert_contains "${OUT}" "uv.lock                            uv lock --upgrade" \
  "naming the lock and the exact command --apply would run"
t_assert_eq "uv | lock --upgrade --dry-run | m1" "${ARGV}" "the report half runs the dry run, never the upgrade"
t_assert_contains "${OUT}" "behind: unknown -- 'uv lock --upgrade --dry-run' printed no summary read here" \
  "a stub's empty output is not read as zero"

t_case "(M2) --apply refreshes a lock that no reported update touches"
_maint "${MAINT_CFG}" "${M1}" "${PEP_REPORT}" --apply --managers pep621
t_assert_eq "uv | lock --upgrade | m1" "${ARGV}" "uv lock --upgrade ran, once, in the lock's own directory"
t_assert_eq "0" "${RC}" "and the run succeeds"
t_assert_ok git -C "${M1}" diff --quiet HEAD -- pyproject.toml
t_assert_contains "${OUT}" "lock file maintenance: any entry may have moved" \
  "the read-back does not pretend to name one dependency"

t_case "(M3) with lockFileMaintenance off, nothing is listed and --apply runs nothing"
_maint "${CONFIG}" "${M1}" "${PEP_REPORT}" --apply --managers pep621
t_assert_fails test -n "$(printf '%s' "${OUT}" | grep 'LOCK FILE MAINTENANCE')"
t_assert_contains "${OUT}" "nothing to apply" "the run says there is nothing to do"
t_assert_eq "0:" "${RC}:${ARGV}" "it exits 0 and runs no lock tool"

t_case "(M4) a packageRule disabling the manager disables its maintenance too, as in Renovate"
_maint "${RULE_OFF_CFG}" "${M1}" "${PEP_REPORT}" --apply --managers pep621
t_assert_eq "0:" "${RC}:${ARGV}" "the rule's enabled:false reaches the maintenance job"

t_case "(M5) a missing lock tool refuses the maintenance run before anything is written"
RUN_CONFIG="${MAINT_CFG}" _run "${M1}" "${PEP_REPORT}" --apply --managers pep621
t_assert_eq "1" "${RC}" "the run must FAIL, as for an edit's lock"
t_assert_contains "${OUT}" "uv.lock needs 'uv', which is not on this PATH" "naming the lock and the tool"

t_case "(M6) --dry-run lists the maintained lock and runs nothing"
_maint "${MAINT_CFG}" "${M1}" "${PEP_REPORT}" --apply --dry-run --managers pep621
t_assert_contains "${OUT}" "uv.lock via uv lock --upgrade (lock file maintenance)" "the job is in the plan"
t_assert_eq "0:" "${RC}:${ARGV}" "a clean dry run exits 0 and runs nothing"

t_case "(M7) workspace members share the root lock, so it is refreshed once"
M7="$(_plant_all m7 \
  Cargo.toml '[workspace]\nmembers = ["crates/a", "crates/b"]\n' \
  crates/a/Cargo.toml '[package]\nname = "a"\n' \
  crates/b/Cargo.toml '[package]\nname = "b"\n' \
  Cargo.lock '# placeholder\n')"
M7_REPORT="${WORK}/m7.json"
_lock_report "${M7_REPORT}" cargo crates/a/Cargo.toml crates/b/Cargo.toml
_maint "${MAINT_CFG}" "${M7}" "${M7_REPORT}" --apply --managers cargo
t_assert_eq "0:cargo | update | m7" "${RC}:${ARGV}" "one cargo update, at the workspace root"

t_case "(M8) one lock under an edit and under maintenance: refreshed for the edit, then upgraded"
M8="$(_plant_all m8 pyproject.toml "${PEP_TOML}" uv.lock '# placeholder\n')"
M8_REPORT="${WORK}/m8.json"
_report "${M8_REPORT}" pep621 pyproject.toml ruff ==0.9.0 ==0.16.6
_maint "${MAINT_CFG}" "${M8}" "${M8_REPORT}" --apply --managers pep621
t_assert_eq "$(printf '0:uv | lock | m8\nuv | lock --upgrade | m8')" "${RC}:${ARGV}" \
  "uv lock for the edit, then uv lock --upgrade, so the lock ends at the newest"
t_assert_contains "$(cat "${M8}/pyproject.toml")" '"ruff==0.16.6"' "and the edit itself landed"

t_case "(M9) a lock with no maintenance command here is NOT CARRIED, and the run exits 2"
M9="$(_plant_all m9 package.json '{"name": "fixture"}\n' yarn.lock '# placeholder\n')"
M9_REPORT="${WORK}/m9.json"
_lock_report "${M9_REPORT}" npm package.json
_maint "${MAINT_CFG}" "${M9}" "${M9_REPORT}" --apply --managers npm
t_assert_eq "2:" "${RC}:${ARGV}" "an unrefreshed maintained lock is not 'everything applied'"
t_assert_contains "${OUT}" "yarn.lock  (yarn: no lock file maintenance command known here" \
  "it is listed by name under NOT CARRIED"

t_case "(M10) an upgrade that fails puts the lock back"
M10="$(_plant_all m10 pyproject.toml "${PEP_TOML}" uv.lock '# lock-before\n')"
M10_STUBS="${WORK}/m10-stubs"
mkdir -p "${M10_STUBS}"
printf '#!/usr/bin/env bash\nprintf "half\\n" >> uv.lock\nexit 1\n' > "${M10_STUBS}/uv"
chmod +x "${M10_STUBS}/uv"
STUB_PATH="${M10_STUBS}:${BARE_PATH}" RUN_CONFIG="${MAINT_CFG}" \
  _run "${M10}" "${PEP_REPORT}" --apply --managers pep621
t_assert_eq "1" "${RC}" "the run must FAIL"
t_assert_eq "# lock-before" "$(cat "${M10}/uv.lock")" "the lock is back at its bytes"

# _dry_stubs <name> <tool> <rc> <output, printf -b> -> a PATH dir whose <tool> logs argv, prints that, exits <rc>.
_dry_stubs() {
  local d="${WORK}/dry-$1"
  mkdir -p "${d}"
  printf '%b' "$4" > "${d}/out.txt"
  printf '#!/usr/bin/env bash\nprintf "%%s | %%s | %%s\\n" "$(basename "$0")" "$*" "${PWD##*/}" >> "%s"\ncat "%s" >&2\nexit %s\n' \
    "${ARGV_LOG}" "${d}/out.txt" "$3" > "${d}/$2"
  chmod +x "${d}/$2"
  printf '%s' "${d}"
}

# _dry <stubs> <repo> <report> <args...>: a report run with only that stub ahead of the bare PATH.
_dry() {
  local stubs="$1"
  shift
  : > "${ARGV_LOG}"
  STUB_PATH="${stubs}:${BARE_PATH}" RUN_CONFIG="${MAINT_CFG}" _run "$@"
  ARGV="$(cat "${ARGV_LOG}")"
}

# The outputs below are verbatim from the real tools, 2026-10-08: uv 0.9.18, cargo 1.96.0, Dart 3.13.3.
UV_DRY='Using CPython 3.14.2\nResolved 3 packages in 56ms\nRemove idna v3.4\nUpdate ruff v0.9.0 -> v0.16.10\nAdd six v1.17.0\n'
CARGO_DRY='    Updating crates.io index\n     Locking 3 packages to latest compatible versions\n    Updating itoa v1.0.1 -> v1.0.18\n      Adding quote v1.0.47\n    Updating serde v1.0.100 -> v1.0.229\nwarning: not updating lockfile due to dry run\n'
DART_DRY='Resolving dependencies...\nDownloading packages...\n> meta 1.19.0 (was 1.9.0)\n> path 1.9.1 (was 1.8.0)\nWould change 2 dependencies.\n'

t_case "(M11) report: a uv lock gets uv's own dry-run count, and the lock is not written"
M11="$(_plant_all m11 pyproject.toml "${PEP_TOML}" uv.lock '# lock-before\n')"
_dry "$(_dry_stubs m11 uv 0 "${UV_DRY}")" "${M11}" "${PEP_REPORT}" --managers pep621
t_assert_eq "0" "${RC}" "a report exits 0"
t_assert_contains "${OUT}" "uv lock --upgrade  (3 entries would move)" "Remove, Update and Add each count"
t_assert_eq "uv | lock --upgrade --dry-run | m11" "${ARGV}" "the dry run, once, in the lock's directory"
t_assert_eq "# lock-before" "$(cat "${M11}/uv.lock")" "the lock keeps its bytes"

t_case "(M12) report: cargo's dry run counts changed entries, not its index line"
M12="$(_cargo_repo m12)"
M12_REPORT="${WORK}/m12.json"
_lock_report "${M12_REPORT}" cargo Cargo.toml
_dry "$(_dry_stubs m12 cargo 0 "${CARGO_DRY}")" "${M12}" "${M12_REPORT}" --managers cargo
t_assert_contains "${OUT}" "cargo update  (3 entries would move)" "two updates and one add"
t_assert_eq "cargo | update --dry-run | m12" "${ARGV}" "cargo update --dry-run ran"

t_case "(M13) report: dart's own summary line is the count, and one is singular"
M13="$(_plant_all m13 pubspec.yaml 'name: fixture\ndependencies:\n  path: ^1.8.0\n' pubspec.lock '# placeholder\n')"
M13_REPORT="${WORK}/m13.json"
_lock_report "${M13_REPORT}" pub pubspec.yaml
_dry "$(_dry_stubs m13 dart 0 "${DART_DRY}")" "${M13}" "${M13_REPORT}" --managers pub
t_assert_contains "${OUT}" "dart pub upgrade  (2 entries would move)" "Would change 2 dependencies."
t_assert_eq "dart | pub upgrade --dry-run | m13" "${ARGV}" "dart pub upgrade --dry-run ran"
_dry "$(_dry_stubs m13-one dart 0 'Would change 1 dependency.\n')" "${M13}" "${M13_REPORT}" --managers pub
t_assert_contains "${OUT}" "dart pub upgrade  (1 entry would move)" "Would change 1 dependency."
_dry "$(_dry_stubs m13-zero dart 0 'No dependencies would change.\n')" "${M13}" "${M13_REPORT}" --managers pub
t_assert_contains "${OUT}" "dart pub upgrade  (0 entries would move)" "an up-to-date lock says 0"

t_case "(M14) report: npm has no dry run that diffs the lock, so it says unknown and runs nothing"
M14="$(_plant_all m14 package.json '{"name": "fixture"}\n' package-lock.json '{}\n')"
M14_REPORT="${WORK}/m14.json"
_lock_report "${M14_REPORT}" npm package.json
_dry "$(_dry_stubs m14 npm 0 'up to date\n')" "${M14}" "${M14_REPORT}" --managers npm
t_assert_contains "${OUT}" "(behind: unknown -- npm has no dry run that diffs the lock)" "never a guessed 0"
t_assert_eq "0:" "${RC}:${ARGV}" "and npm is not run at all"

t_case "(M15) report: a missing tool, a failing dry run and an unreadable one each say unknown"
_dry "${BARE_PATH}" "${M11}" "${PEP_REPORT}" --managers pep621
t_assert_eq "0" "${RC}" "a missing tool does not fail a report"
t_assert_contains "${OUT}" "(behind: unknown -- 'uv' is not on this PATH)" "the missing tool is named"
_dry "$(_dry_stubs m15-fail uv 2 "${UV_DRY}")" "${M11}" "${PEP_REPORT}" --managers pep621
t_assert_contains "${OUT}" "(behind: unknown -- 'uv lock --upgrade --dry-run' failed (exit 2))" \
  "a failed dry run is not counted, whatever it printed"
_dry "$(_dry_stubs m15-junk uv 0 'error: no network\n')" "${M11}" "${PEP_REPORT}" --managers pep621
t_assert_contains "${OUT}" "printed no summary read here" "output without the tool's summary is not zero"

t_case "(M16) report: a dry run that writes the lock is put back and not believed"
M16_STUBS="${WORK}/dry-m16"
mkdir -p "${M16_STUBS}"
printf '#!/usr/bin/env bash\nprintf "written\\n" > uv.lock\nprintf "Resolved 1 package in 1ms\\n"\n' > "${M16_STUBS}/uv"
chmod +x "${M16_STUBS}/uv"
_dry "${M16_STUBS}" "${M11}" "${PEP_REPORT}" --managers pep621
t_assert_contains "${OUT}" "wrote the lock, now put back" "the report says so"
t_assert_eq "# lock-before" "$(cat "${M11}/uv.lock")" "and the lock is back at its bytes"
t_assert_ok git -C "${M11}" diff --quiet HEAD -- uv.lock

t_summary
