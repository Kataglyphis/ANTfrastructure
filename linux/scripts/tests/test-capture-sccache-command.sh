#!/usr/bin/env bash
# Fake cache and child commands prove raw status and evidence retention, not actual compiler cache hits.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
work="$(t_mktemp -d)" || exit 1
mkdir "${work}/bin" || exit 1
cat > "${work}/bin/sccache" <<'STUB'
#!/usr/bin/env bash
printf 'fixture cache stats %s\n' "$*"
exit "${CACHE_FIXTURE_STATUS:-0}"
STUB
chmod +x "${work}/bin/sccache" || exit 1
export PATH="${work}/bin:${PATH}"
runner="${TESTS_DIR}/../capture-sccache-command.sh"
run_case() { bash "${runner}" "${work}/$1" -- bash -c 'exit "$1"' bash "$2" >"${work}/stdout" 2>"${work}/stderr"; }
t_case 'cache evidence retains the command and stats statuses'
t_assert_ok run_case good 0
t_assert_contains "$(cat "${work}/good/exit-status.txt")" 'command_status=0'
t_assert_contains "$(cat "${work}/stderr")" 'fixture cache stats'
t_assert_ok test -s "${work}/good/cache-stats.json"
t_assert_rc 42 run_case failed 42
t_assert_contains "$(cat "${work}/failed/exit-status.txt")" 'command_status=42'
export CACHE_FIXTURE_STATUS=9
t_assert_rc 9 run_case cache-failed 0
t_assert_rc 42 run_case both-failed 42
t_assert_contains "$(cat "${work}/both-failed/exit-status.txt")" 'cache_stats_status=9'
t_assert_rc 1 run_case good 0
t_assert_contains "$(cat "${work}/good/exit-status.txt")" 'command_status=0'
t_assert_ok bash "${runner}" --help
t_assert_rc 2 bash "${runner}"
t_assert_rc 2 bash "${runner}" "${work}/incomplete" --
t_assert_rc 2 bash "${runner}" "${work}/bad-separator" invalid true
t_summary
