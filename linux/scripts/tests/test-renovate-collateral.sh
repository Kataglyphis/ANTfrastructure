#!/usr/bin/env bash
# Each case drives a lock tool that misbehaves in exactly one way; see docs/dependency-updates.md#nothing-else-in-the-repo-moved
set -u
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/renovate-fixtures.sh"

# _cs_tool <body>: a `dart` that runs <body> and exits 0; a failing tool is test-renovate-local.sh's (D).
CS_PATH=""
_cs_tool() {
  local d
  d="$(mktemp -d "${WORK}/cs.XXXXXX")"
  {
    printf '#!/usr/bin/env bash\n'
    printf '%s\n' "$1"
    printf 'exit 0\n'
  } > "${d}/dart"
  chmod +x "${d}/dart"
  CS_PATH="${d}:${BARE_PATH}"
}

# _cs_repo <name>: pubspec, lockfile, tracked generated files, and a .gitignore to tell build/ from lib/.
_cs_repo() {
  local d
  d="$(_plant "$1" pubspec.yaml 'name: fixture\ndependencies:\n  http: 1.1.0\n')"
  mkdir -p "${d}/lib/l10n"
  _plant_file "${d}" pubspec.lock '# placeholder\n'
  _plant_file "${d}" lib/l10n/app_localizations.dart 'generated one\n'
  _plant_file "${d}" lib/l10n/app_localizations_de.dart 'generated de\n'
  _plant_file "${d}" .gitignore 'build/\n'
  printf '%s' "${d}"
}

# _cs_run_with <repo> <report> <tool body> [flags]: one case's whole run, shared so the dupes gate sees no copy.
_cs_run_with() {
  local repo="$1" report="$2" body="$3"
  shift 3
  _cs_tool "${body}"
  STUB_PATH="${CS_PATH}" _run "${repo}" "${report}" --apply --managers pub "$@"
}

# The same, for the majority of cases, which drive the one pub report.
_cs_run() {
  local repo="$1" body="$2"
  shift 2
  _cs_run_with "${repo}" "${A_REPORT}" "${body}" "$@"
}

# (K1) A tool that deletes a tracked file it was not asked about: the case the guard exists for.
t_case "(K1) a lock tool that deletes a tracked file refuses the whole run"
K1="$(_cs_repo k1)"
_cs_run "${K1}" 'rm -f lib/l10n/app_localizations.dart lib/l10n/app_localizations_de.dart'
t_assert_eq "1" "${RC}" "the run must FAIL, not report success with files gone"
t_assert_contains "${OUT}" "COLLATERAL" "the refusal says what kind of problem it is"
t_assert_contains "${OUT}" "lib/l10n/app_localizations.dart" "and NAMES the path"
t_assert_contains "${OUT}" "lib/l10n/app_localizations_de.dart" "every one of them"
t_assert_contains "${OUT}" "DELETED, and it is tracked" "and says what happened to it"
t_assert_eq "generated one" "$(cat "${K1}/lib/l10n/app_localizations.dart")" \
  "the deleted file is back"
t_assert_eq "generated de" "$(cat "${K1}/lib/l10n/app_localizations_de.dart")" \
  "both of them"
t_assert_eq "  http: 1.1.0" "$(_pub "${K1}" 3)" "and the manifest is back too"
t_assert_eq "0" "$(t_rc git -C "${K1}" diff --quiet HEAD)" \
  "the whole tree is exactly where it started"

# (K2) Catching only deletion would let a created file into the next `git add -A`.
t_case "(K2) a lock tool that creates an untracked file refuses, and it is removed"
K2="$(_cs_repo k2)"
_cs_run "${K2}" 'mkdir -p lib/gen && printf "x\n" > lib/gen/thing.dart'
t_assert_eq "1" "${RC}" "the run must FAIL"
t_assert_contains "${OUT}" "lib/gen/thing.dart" "the created path is named"
t_assert_contains "${OUT}" "(created)" "and said to be created rather than edited"
t_assert_fails test -f "${K2}/lib/gen/thing.dart"
t_assert_eq "  http: 1.1.0" "$(_pub "${K2}" 3)" "the manifest is back"

# (K3) A path already dirty at the start is never checked out over: that would destroy the human's work.
t_case "(K3) collateral on an ALREADY dirty path is named and deliberately kept"
K3="$(_cs_repo k3)"
printf 'my own work in progress\n' > "${K3}/lib/l10n/app_localizations.dart"
_cs_run "${K3}" 'printf "the tool wrote this\n" > lib/l10n/app_localizations.dart'
t_assert_eq "1" "${RC}" "the run must still FAIL"
t_assert_contains "${OUT}" "ALREADY carrying local changes" "under its own heading"
t_assert_contains "${OUT}" "lib/l10n/app_localizations.dart" "naming the path"
t_assert_contains "${OUT}" "The tree is NOT as it started in these paths" \
  "and saying plainly that the tree did not fully go back"
t_assert_eq "the tool wrote this" "$(cat "${K3}/lib/l10n/app_localizations.dart")" \
  "the path is left exactly as the tool left it -- not checked out over"
t_assert_eq "  http: 1.1.0" "$(_pub "${K3}" 3)" "the manifest is still put back"

# (K4) An ignored path cannot reach a commit, and refusing over `.dart_tool/` would make the guard unusable.
t_case "(K4) a tool writing only into an IGNORED directory is not collateral"
K4="$(_cs_repo k4)"
_cs_run "${K4}" 'mkdir -p build/cache && printf "junk\n" > build/cache/x && printf "packages: {}\n" > pubspec.lock'
t_assert_eq "0" "${RC}" "the run must succeed"
t_assert_eq "  http: 1.6.0" "$(_pub "${K4}" 3)" "and the update is applied"
t_assert_fails grep -q COLLATERAL <<<"${OUT}"
t_assert_ok test -f "${K4}/build/cache/x"

# (K5) The lock tool runs beside the audited manifest and can rewrite the file the proof was about.
t_case "(K5) a lock tool that rewrites the audited manifest refuses the run"
K5="$(_cs_repo k5)"
_cs_run "${K5}" 'printf "name: fixture\ndependencies:\n  http: 9.9.9\n" > pubspec.yaml'
t_assert_eq "1" "${RC}" "the run must FAIL"
t_assert_contains "${OUT}" "REWROTE a manifest this run had already audited" \
  "and say which guarantee was voided"
t_assert_contains "${OUT}" "pubspec.yaml" "naming the manifest"
t_assert_eq "  http: 1.1.0" "$(_pub "${K5}" 3)" "the manifest is back at its ORIGINAL value"

# (K6) A rewritten lockfile cannot be audited per value, but present, non-empty and parseable can be checked.
t_case "(K6) a lock tool that truncates its lockfile refuses the run"
K6="$(_cs_repo k6)"
_cs_run "${K6}" ': > pubspec.lock'
t_assert_eq "1" "${RC}" "the run must FAIL"
t_assert_contains "${OUT}" "this is what the tool" "framed as the TOOL's doing, not the tree's"
t_assert_contains "${OUT}" "the lockfile is EMPTY" "saying what it found"
t_assert_eq "  http: 1.1.0" "$(_pub "${K6}" 3)" "the manifest is back"
t_assert_eq "# placeholder" "$(cat "${K6}/pubspec.lock")" "and so is the lockfile"

t_case "(K6b) a lock tool that leaves unparseable YAML behind refuses the run"
K6B="$(_cs_repo k6b)"
_cs_run "${K6B}" 'printf "packages: {oops\n" > pubspec.lock'
t_assert_eq "1" "${RC}" "the run must FAIL"
t_assert_contains "${OUT}" "it does not read as yaml" \
  "naming the parser that would not read it"
t_assert_eq "# placeholder" "$(cat "${K6B}/pubspec.lock")" "the lockfile is back"

# (K7) The lockfile is also read before the run, so a failure after it means the tool broke it.
t_case "(K7) a lockfile that was ALREADY unreadable refuses before anything is written"
K7="$(_cs_repo k7)"
printf 'packages: {already broken\n' > "${K7}/pubspec.lock"
_commit "${K7}"
_cs_run "${K7}" 'printf "packages: {}\n" > pubspec.lock'
t_assert_eq "1" "${RC}" "the run must FAIL"
t_assert_contains "${OUT}" "BEFORE anything is written" \
  "and blame the TREE rather than this run"
t_assert_eq "  http: 1.1.0" "$(_pub "${K7}" 3)" "nothing was written"
t_assert_contains "$(cat "${K7}/pubspec.lock")" "already broken" \
  "and the lock the tool would have fixed was never run over"

# (K8) A guard that passes silently cannot be told apart from one that checked nothing.
t_case "(K8) a well-behaved tool applies, and the run says what it proved"
K8="$(_cs_repo k8)"
_cs_run "${K8}" 'printf "packages:\n  http:\n    version: \"1.6.0\"\n" > pubspec.lock'
t_assert_eq "0" "${RC}" "the run must succeed"
t_assert_eq "  http: 1.6.0" "$(_pub "${K8}" 3)" "the update is applied"
t_assert_contains "${OUT}" "what can be said about the refreshed lockfile(s)" \
  "the narrower claim is stated rather than implied"
t_assert_contains "${OUT}" "pubspec.lock: parses as yaml, and names 'http'" \
  "naming the parser AND whether the dep is in it"

t_case "(K8b) a lockfile the tool did not put the dep in is REPORTED, not refused"
K8B="$(_cs_repo k8b)"
_cs_run "${K8B}" 'printf "packages: {}\n" > pubspec.lock'
t_assert_eq "0" "${RC}" "an unproveable claim is not a refusal"
t_assert_contains "${OUT}" "does NOT name 'http'" "but it is said out loud"

# (K9) --dry-run runs no ecosystem tool, so there is no collateral; the pre-flight lock read still runs.
t_case "(K9) --dry-run runs no tool, so it finds no collateral and changes nothing"
K9="$(_cs_repo k9)"
_cs_run "${K9}" 'rm -f lib/l10n/app_localizations.dart' --dry-run
t_assert_eq "0" "${RC}" "the plan must print"
t_assert_fails grep -q COLLATERAL <<<"${OUT}"
t_assert_ok test -f "${K9}/lib/l10n/app_localizations.dart"
t_assert_eq "  http: 1.1.0" "$(_pub "${K9}" 3)" "and nothing is written"

# (K10) The boundary is the rollback's reach, so a second manifest this run edits is expected.
t_case "(K10) a file this run legitimately writes is never called collateral"
K10="$(_cs_repo k10)"
mkdir -p "${K10}/app"
printf 'name: app\ndependencies:\n  http: 1.1.0\n' > "${K10}/app/pubspec.yaml"
_commit "${K10}"
K10_REPORT="${WORK}/k10.json"
_report_pair "${K10_REPORT}" pub http 1.1.0 1.6.0 pubspec.yaml app/pubspec.yaml
_cs_run_with "${K10}" "${K10_REPORT}" 'printf "packages: {}\n" > pubspec.lock'
t_assert_eq "0" "${RC}" "both manifests are this run's own work"
t_assert_fails grep -q COLLATERAL <<<"${OUT}"
t_assert_eq "  http: 1.6.0" "$(_pub "${K10}" 3)" "the first moved"
t_assert_eq "  http: 1.6.0" "$(_line "${K10}/app/pubspec.yaml" 3)" "and so did the second"

# (K11)-(K23): staged changes, submodules, spaces, scope, line endings and workspaces, which the cases above never reach.

# (K11) The re-read after a restore must call a path that did not go back stuck, and keep the only copies.
t_case "(K11) a path that will NOT go back is called stuck, and the copies are kept"
K11="$(_cs_repo k11)"
K11_TMP="${WORK}/k11-tmp"; mkdir -p "${K11_TMP}"
_cs_tool 'rm -f lib/l10n/app_localizations.dart && chmod 555 lib/l10n'
STUB_PATH="${CS_PATH}" RUN_TMPDIR="${K11_TMP}" \
  _run "${K11}" "${A_REPORT}" --apply --managers pub
chmod 755 "${K11}/lib/l10n"
t_assert_eq "1" "${RC}" "the run must FAIL"
t_assert_contains "${OUT}" "could NOT be put back" "and say the undo did not finish"
t_assert_contains "${OUT}" "still differs after being put back" "naming the proof that failed"
t_assert_fails grep -q "they were put back" <<<"${OUT}"
t_assert_eq "1" "$(find "${K11_TMP}" -mindepth 1 -maxdepth 1 -type d | wc -l)" \
  "the copies are kept -- nothing proved them unnecessary"
t_assert_ok test -f "${K11}/.git/renovate-local-inflight"

# (K12)-(K13) The restore checks out HEAD, not the index, so a tool that stages its change is undone too.
t_case "(K12) a STAGED deletion is put back and unstaged, not left gone"
K12="$(_cs_repo k12)"
_cs_run "${K12}" 'git rm -q -f lib/l10n/app_localizations.dart'
t_assert_eq "1" "${RC}" "the run must FAIL"
t_assert_eq "generated one" "$(cat "${K12}/lib/l10n/app_localizations.dart" 2>&1)" \
  "the file is back with the bytes it had"
t_assert_eq "" "$(git -C "${K12}" status --porcelain=v1 -uall)" \
  "and nothing is left staged: checkout HEAD rewrites the index too"

t_case "(K13) a STAGED modification is put back, not accepted as already correct"
K13="$(_cs_repo k13)"
_cs_run "${K13}" 'printf "the tool wrote this\n" > lib/l10n/app_localizations.dart && git add lib/l10n/app_localizations.dart'
t_assert_eq "1" "${RC}" "the run must FAIL"
t_assert_eq "generated one" "$(cat "${K13}/lib/l10n/app_localizations.dart")" \
  "a checkout from the INDEX would have been a no-op and left the tool's bytes"
t_assert_eq "" "$(git -C "${K13}" status --porcelain=v1 -uall)" "and nothing is staged"

# (K14) The collateral snapshot must look inside submodules; path dependencies can live in one.
t_case "(K14) a tool that writes INSIDE a submodule is seen, named and refused"
_k14_repo() {
  local d
  d="$(_cs_repo "$1")"
  _vendor_sub "${d}" "$1" 'tracked inside the submodule\n' >/dev/null
  _commit "${d}"
  printf '%s' "${d}"
}
K14="$(_k14_repo k14)"
_cs_run "${K14}" 'rm -f sub/f.txt && printf "junk\n" > sub/extra.txt && printf "packages: {}\n" > pubspec.lock'
t_assert_eq "1" "${RC}" "the run must FAIL rather than exit 0 over it"
t_assert_contains "${OUT}" "COLLATERAL" "and say what kind of problem it is"
t_assert_contains "${OUT}" "it is a SUBMODULE" "and which kind of path"
t_assert_contains "${OUT}" "could NOT be put back" \
  "because no checkout of the gitlink can reach what moved inside it"
t_assert_eq "  http: 1.1.0" "$(_pub "${K14}" 3)" "the manifest is back"

# (K15)-(K16) Ownership must be an exact path match; porcelain C-quotes a path with a space.
_k15_repo() {
  _plant_all "$1" \
    'app one/pubspec.yaml' 'name: fixture\ndependencies:\n  http: 1.1.0\n' \
    'app one/pubspec.lock' '# placeholder\n' \
    app 'a tracked file called app\n' \
    one/pubspec.lock 'a tracked file called one/pubspec.lock\n'
}
K15_REPORT="${WORK}/k15.json"
_report "${K15_REPORT}" pub 'app one/pubspec.yaml' http 1.1.0 1.6.0

t_case "(K15) an OWNED manifest whose path has a space is not read as collateral"
K15="$(_k15_repo k15)"
_cs_run_with "${K15}" "${K15_REPORT}" 'printf "packages: {}\n" > pubspec.lock'
t_assert_eq "0" "${RC}" "a legitimate run must not refuse over its own work"
t_assert_fails grep -q COLLATERAL <<<"${OUT}"
t_assert_eq "  http: 1.6.0" "$(_line "${K15}/app one/pubspec.yaml" 3)" "the update is applied"

# The victims sit at the repo root, where a substring ownership test would swallow them.
t_case "(K16) ...and it does not swallow the unrelated paths it is a substring of"
K16="$(_k15_repo k16)"
_cs_run_with "${K16}" "${K15_REPORT}" 'top="$(git rev-parse --show-toplevel)"
rm -f "${top}/app" "${top}/one/pubspec.lock"
printf "packages: {}\n" > pubspec.lock'
t_assert_eq "1" "${RC}" "two tracked files were deleted; the run must FAIL"
t_assert_contains "${OUT}" "app  (DELETED, and it is tracked)" "the first is NAMED"
t_assert_contains "${OUT}" "one/pubspec.lock  (DELETED" "and so is the second"
t_assert_eq "a tracked file called app" "$(cat "${K16}/app")" "the first is back"
t_assert_eq "a tracked file called one/pubspec.lock" "$(cat "${K16}/one/pubspec.lock")" \
  "and so is the second"

# (K17) The guard watches only the repo, and a passing run must say so.
t_case "(K17) a passing run states what it watched, and what it did not"
K17="$(_cs_repo k17)"
_cs_run "${K17}" 'printf "packages:\n  http:\n    version: \"1.6.0\"\n" > pubspec.lock'
t_assert_eq "0" "${RC}" "the run must succeed"
t_assert_contains "${OUT}" "WHAT WAS WATCHED" "the scope has a heading of its own"
t_assert_contains "${OUT}" "nothing outside it" "and says where the guard stops"
t_assert_contains "${OUT}" "pub-cache" "naming where an ecosystem tool really writes"

# (K18) An ignored path is not committable, but losing it is still the human's loss, so it is named.
t_case "(K18) an ignored path a tool DELETED is named, even though it is not refused"
K18="$(_cs_repo k18)"
printf 'build/\nsecrets.env\n' > "${K18}/.gitignore"
_commit "${K18}"
printf 'API_TOKEN=the content a human would lose\n' > "${K18}/secrets.env"
_cs_run "${K18}" 'rm -f secrets.env && printf "packages: {}\n" > pubspec.lock'
t_assert_eq "0" "${RC}" "an ignored path is still not a refusal"
t_assert_contains "${OUT}" "secrets.env" "but it is NAMED"
t_assert_contains "${OUT}" "cannot put them back" "and the run says it cannot undo it"

# (K19)-(K20) `flutter pub get` rewrites CRLF checkouts as LF; an EOL-only change is put back, not refused.
_k19_repo() {
  local d
  d="$(_cs_repo "$1")"
  git -C "${d}" config core.autocrlf false
  printf 'line one\r\nline two\r\n' > "${d}/lib/l10n/app_localizations.dart"
  _commit "${d}"
  printf '%s' "${d}"
}
t_case "(K19) a rewrite that changes ONLY line endings is put back, and does not refuse"
K19="$(_k19_repo k19)"
_cs_run "${K19}" 'printf "line one\nline two\n" > lib/l10n/app_localizations.dart && printf "packages: {}\n" > pubspec.lock'
t_assert_eq "0" "${RC}" "the update must apply -- the content did not change"
t_assert_eq "  http: 1.6.0" "$(_pub "${K19}" 3)" "and it did"
t_assert_contains "${OUT}" "different LINE" "the rewrite is still NAMED, not swallowed"
t_assert_contains "${OUT}" "lib/l10n/app_localizations.dart" "with the path"
# Scoped to the path: the manifest and its lock are meant to move on a passing run.
t_assert_eq "0" "$(t_rc git -C "${K19}" diff --quiet HEAD -- lib/l10n/app_localizations.dart)" \
  "and the CRLF bytes are back: named AND put back is what makes not refusing honest"
t_assert_eq "" "$(git -C "${K19}" status --porcelain=v1 -- lib/l10n/app_localizations.dart)" \
  "with nothing left for the next \`git add -A\` to sweep up"

t_case "(K20) a rewrite that changes the CONTENT as well still refuses"
K20="$(_k19_repo k20)"
_cs_run "${K20}" 'printf "line one\nSOMETHING ELSE\n" > lib/l10n/app_localizations.dart && printf "packages: {}\n" > pubspec.lock'
t_assert_eq "1" "${RC}" "line endings are not a licence for the bytes between them"
t_assert_contains "${OUT}" "COLLATERAL" "it is ordinary collateral"
t_assert_eq "  http: 1.1.0" "$(_pub "${K20}" 3)" "and the manifest is back"

# (K21)-(K23) A workspace member's lock lives at the workspace root, so its lock job must be found there.
_k21_repo() {
  _plant_all "$1" \
    Cargo.toml '[workspace]\nmembers = ["crates/foo"]\n' \
    Cargo.lock '# lock-bytes\n' \
    crates/foo/Cargo.toml '[package]\nname = "foo"\n\n[dependencies]\nserde = "=1.0.100"\n'
}
K21_REPORT="${WORK}/k21.json"
_report "${K21_REPORT}" cargo crates/foo/Cargo.toml serde '=1.0.100' '=1.0.200'

t_case "(K21) a workspace member's lock is at the ROOT, and a missing tool refuses"
K21="$(_k21_repo k21)"
_run "${K21}" "${K21_REPORT}" --apply --managers cargo
t_assert_eq "1" "${RC}" "no cargo on this PATH is a REFUSAL, not a silent skip"
t_assert_contains "${OUT}" "needs 'cargo'" "naming the tool that is missing"
t_assert_contains "${OUT}" "Cargo.lock" "and the lockfile it would have refreshed"
t_assert_eq 'serde = "=1.0.100"' "$(_line "${K21}/crates/foo/Cargo.toml" 5)" \
  "and nothing is written"

t_case "(K22) ...and with the tool present it runs in the WORKSPACE root"
K22="$(_k21_repo k22)"
: > "${ARGV_LOG}"
_run_stubbed "${K22}" "${K21_REPORT}" --apply --managers cargo
t_assert_eq "0" "${RC}" "the run completes"
t_assert_eq 'serde = "=1.0.200"' "$(_line "${K22}/crates/foo/Cargo.toml" 5)" "the member moved"
t_assert_contains "$(cat "${ARGV_LOG}")" "cargo | update -p serde@1.0.100 | k22" \
  "and the tool ran in the directory that owns the lock, not the member's"

t_case "(K23) a nested manifest with NO workspace declaration still gets no lock job"
K23="$(_cs_repo k23)"
mkdir -p "${K23}/app"
printf 'name: app\ndependencies:\n  http: 1.1.0\n' > "${K23}/app/pubspec.yaml"
_commit "${K23}"
K23_REPORT="${WORK}/k23.json"
_report "${K23_REPORT}" pub app/pubspec.yaml http 1.1.0 1.6.0
_cs_run_with "${K23}" "${K23_REPORT}" 'printf "packages: {}\n" > pubspec.lock'
t_assert_eq "0" "${RC}" "walking up to any ancestor that merely HAS a lock is the other bug"
t_assert_contains "${OUT}" "none of the edited manifests has a lockfile" \
  "the root pubspec.lock belongs to the root package, not to app/"
t_assert_eq "# placeholder" "$(cat "${K23}/pubspec.lock")" "so it was never touched"

t_summary
