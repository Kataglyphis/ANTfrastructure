#!/usr/bin/env bash
# Tests for 01-core/guard-helpers.sh — first_match / probe / source_vendor /
# csv_each. Pure unit tests: no network, no apt, temp dirs/files only.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
# shellcheck source=../01-core/guard-helpers.sh
source "${TESTS_DIR}/../01-core/guard-helpers.sh"

_tmp="$(mktemp -d)"
trap 'rm -rf "${_tmp}"' EXIT

# ── first_match ───────────────────────────────────────────────────────────────
mkdir -p "${_tmp}/fm/sub"
: > "${_tmp}/fm/a.so"
: > "${_tmp}/fm/sub/libfoo.so.2"

t_case "first_match returns a matching path"
_hit="$(first_match "${_tmp}/fm" -name 'libfoo.so*' -type f)"
t_assert_eq "${_hit}" "${_tmp}/fm/sub/libfoo.so.2"

t_case "first_match returns exactly ONE path even when several match"
: > "${_tmp}/fm/b.so"
_hits="$(first_match "${_tmp}/fm" -name '*.so' -type f | wc -l)"
t_assert_eq "${_hits}" "1"

t_case "first_match on no match returns empty"
_none="$(first_match "${_tmp}/fm" -name 'nope.xyz')"
t_assert_eq "${_none}" ""

t_case "first_match on a MISSING dir returns empty without tripping set -e"
( set -e; r="$(first_match "${_tmp}/does-not-exist" -name '*')"; [ -z "$r" ] )
t_assert_ok true   # reaching here means the subshell above did not abort

# ── probe ─────────────────────────────────────────────────────────────────────
t_case "probe true succeeds"
t_assert_ok probe true

t_case "probe false fails"
t_assert_fails probe false

t_case "probe silences stdout+stderr"
_out="$(probe sh -c 'echo OUT; echo ERR >&2' 2>&1; true)"
t_assert_eq "${_out}" ""

t_case "probe returns the real status (for use in a condition)"
if probe sh -c 'exit 3'; then t_assert_eq "reached" "unreachable"; else t_assert_ok true; fi

# ── source_vendor ─────────────────────────────────────────────────────────────
# A vendored file that references an unset var — would abort a `set -u` caller.
cat > "${_tmp}/vendor.sh" <<'EOF'
VENDOR_SAW="${SOME_DEFINITELY_UNSET_VAR}unset-ok"
EOF

t_case "source_vendor sources an unset-var file under set -u without aborting"
( set -u; source_vendor "${_tmp}/vendor.sh"; [ "${VENDOR_SAW}" = "unset-ok" ] )
t_assert_ok true

t_case "source_vendor RESTORES set -u afterwards (caller had it)"
_restored="$(set -u; source_vendor "${_tmp}/vendor.sh" >/dev/null 2>&1; case "$-" in *u*) echo yes;; *) echo no;; esac)"
t_assert_eq "${_restored}" "yes"

t_case "source_vendor does NOT force -u on when caller lacked it"
_forced="$(set +u; source_vendor "${_tmp}/vendor.sh" >/dev/null 2>&1; case "$-" in *u*) echo yes;; *) echo no;; esac)"
t_assert_eq "${_forced}" "no"

t_case "source_vendor propagates the sourced file's exit status"
printf 'return 7\n' > "${_tmp}/rc.sh"
if source_vendor "${_tmp}/rc.sh"; then t_assert_eq "rc" "should-have-failed"; else t_assert_eq "$?" "7"; fi

# ── csv_each ──────────────────────────────────────────────────────────────────
_CSV_SEEN=""
_csv_collect() { _CSV_SEEN="${_CSV_SEEN}[$1]"; }

t_case "csv_each calls fn once per element in order"
_CSV_SEEN=""; csv_each "amd64,arm64,riscv64" _csv_collect
t_assert_eq "${_CSV_SEEN}" "[amd64][arm64][riscv64]"

t_case "csv_each skips empty elements"
_CSV_SEEN=""; csv_each "a,,c" _csv_collect
t_assert_eq "${_CSV_SEEN}" "[a][c]"

t_case "csv_each on empty string calls fn zero times"
_CSV_SEEN="none"; csv_each "" _csv_collect
t_assert_eq "${_CSV_SEEN}" "none"

t_case "csv_each does NOT leak IFS to the caller"
IFS_before="$IFS"; csv_each "x,y" _csv_collect; t_assert_eq "$IFS" "${IFS_before}"

t_summary
