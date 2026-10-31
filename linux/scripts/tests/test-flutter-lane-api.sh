#!/usr/bin/env bash
# flutter-pin.sh and lane-prologue.sh are consumer API whose callers are consumer copies (BACKLOG CON211); these cases pin argv, status and output.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=linux/scripts/tests/lib-contract-fixture.sh
source "${TESTS_DIR}/lib-contract-fixture.sh"
source "${TESTS_DIR}/test-workspace-fixture.sh"
declare _work
t_fixture_workspace_init _work || exit 1
lc_init "${_work}" || exit 1
PIN="${TESTS_DIR}/../05-frameworks/flutter/flutter-pin.sh"
LANE="${TESTS_DIR}/../05-frameworks/flutter/lane-prologue.sh"
LOG="${_work}/argv.log"
declare out rc

t_case "flutter_resolve_pin exports the version and its tarball sha from versions.env as one pin"
lc_call out rc "${PIN}" 'unset FLUTTER_VERSION FLUTTER_SDK_SHA256; flutter_resolve_pin; printf "%s|%s|%s\n" "${FLUTTER_VERSION}" "${FLUTTER_SDK_SHA256}" "$(flutter_pin_versions_env)"'
t_assert_eq "0" "${rc}"
_env="${out##*|}"
_want="$(sed -n 's/^FLUTTER_VERSION=//p' "${_env}")|$(sed -n 's/^FLUTTER_SDK_SHA256=//p' "${_env}")|${_env}"
t_assert_eq "${_want}" "$(printf '%s\n' "${out}" | tail -1)"
t_assert_contains "${out}" "[Info] Flutter ${_want%%|*} (pinned in ${_env})."

t_case "a caller's FLUTTER_VERSION wins and leaves the sha unset, so setup-flutter.sh names the mismatch"
lc_call out rc "${PIN}" 'unset FLUTTER_SDK_SHA256; export FLUTTER_VERSION=3.0.0; flutter_resolve_pin; printf "%s|%s\n" "${FLUTTER_VERSION}" "${FLUTTER_SDK_SHA256:-unset}"'
t_assert_eq "0" "${rc}"
t_assert_eq "3.0.0|unset" "${out}"

t_case "half a pin, or no versions.env at all, fails with the file it read"
t_fn_src "${PIN}" flutter_resolve_pin > "${_work}/resolve.sh" || exit 1
printf 'FLUTTER_VERSION=3.99.0\n' > "${_work}/versions.env"
lc_call out rc "${_work}/resolve.sh" "flutter_pin_versions_env() { printf %s $(printf '%q' "${_work}/versions.env"); }; unset FLUTTER_VERSION; flutter_resolve_pin"
t_assert_eq "1" "${rc}"
t_assert_contains "${out}" "Error: FLUTTER_VERSION and FLUTTER_SDK_SHA256 are not both pinned in"
t_assert_contains "${out}" "${_work}/versions.env. They are one pin; fix it there."
lc_call out rc "${_work}/resolve.sh" 'flutter_pin_versions_env() { return 1; }; flutter_resolve_pin'
t_assert_eq "1" "${rc}"

mkdir -p "${_work}/sdk/bin" "${_work}/repo" "${_work}/home"
printf '#!/usr/bin/env bash\necho "sdk-flutter $*" >> %q\nexit %s\n' "${LOG}" "$(lc_status sdk-flutter)" > "${_work}/sdk/bin/flutter"
chmod +x "${_work}/sdk/bin/flutter"
lc_stub git
ENV="export HOME=$(printf '%q' "${_work}/home") KATAGLYPHIS_REPO_ROOT=$(printf '%q' "${_work}/repo"); unset PUB_CACHE"
SHOW='printf "dir=%s pub=%s path=%s\n" "${FLUTTER_DIR}" "${PUB_CACHE}" "${PATH%%:*}"'

t_case "flutter_lane_prepare_env puts the SDK first on PATH once, trusts the repo root and keeps pub's cache in it"
lc_call out rc "${LANE}" "${ENV}; flutter_lane_prepare_env $(printf '%q' "${_work}/sdk") && flutter_lane_prepare_env $(printf '%q' "${_work}/sdk") && ${SHOW}; echo \"\${PATH}\" | tr ':' '\n' | grep -c -x -F $(printf '%q' "${_work}/sdk/bin")"
t_assert_eq "0" "${rc}"
t_assert_eq "git config --global --add safe.directory ${_work}/repo
sdk-flutter --version
git config --global --add safe.directory ${_work}/repo
sdk-flutter --version" "$(lc_argv)"
t_assert_contains "${out}" "dir=${_work}/sdk pub=${_work}/repo/.pub-cache path=${_work}/sdk/bin"
t_assert_eq "1" "$(printf '%s\n' "${out}" | tail -1)" "a second call does not add the SDK to PATH again"

t_case "FLUTTER_DIR and a caller's PUB_CACHE are kept; the repo root falls back to the current directory"
lc_reset
lc_call out rc "${LANE}" "${ENV}; unset KATAGLYPHIS_REPO_ROOT; export PUB_CACHE=/cache FLUTTER_DIR=$(printf '%q' "${_work}/sdk"); flutter_lane_prepare_env && ${SHOW}"
t_assert_eq "0" "${rc}"
t_assert_eq "git config --global --add safe.directory ${_work}" "$(lc_argv | sed -n 1p)"
t_assert_contains "${out}" "dir=${_work}/sdk pub=/cache"

t_case "a missing SDK, a git that cannot record the root, or a flutter that cannot start each fail with a reason"
lc_expect 1 "no Flutter SDK at /nonexistent/flutter." "${LANE}" "${ENV}; flutter_lane_prepare_env /nonexistent/flutter"
lc_fail git 4
lc_expect 1 "could not record ${_work}/repo as a git safe.directory (HOME=${_work}/home)." "${LANE}" "${ENV}; flutter_lane_prepare_env $(printf '%q' "${_work}/sdk")"
lc_pass git
lc_fail sdk-flutter 3
lc_reset
lc_call out rc "${LANE}" "${ENV}; flutter_lane_prepare_env $(printf '%q' "${_work}/sdk")"
t_assert_eq "1" "${rc}"
t_assert_contains "$(lc_argv)" "sdk-flutter --version"
lc_pass sdk-flutter

t_case "flutter_build_web builds release web, names the two shared flags and forwards the rest"
lc_stub flutter
lc_reset
lc_call out rc "${LANE}" 'flutter_build_web --wasm --dart-define=A=1 --no-tree-shake-icons'
t_assert_eq "0" "${rc}"
t_assert_eq "flutter build web --release --wasm --dart-define=A=1 --no-tree-shake-icons" "$(lc_argv)"
t_assert_contains "${out}" "flutter build web --release --wasm --dart-define=A=1 --no-tree-shake-icons"
lc_fail flutter 7
lc_call out rc "${LANE}" 'flutter_build_web'
t_assert_eq "7" "${rc}" "flutter's status is the function's"
lc_pass flutter

t_summary
