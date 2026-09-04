#!/usr/bin/env bash
# Tests for verify_shellcheck_warnings.py and the two lint-shell.sh modes it owns
# (--list-files for the scope, --print-bin for the pinned binary). Each case copies
# the gate into a throwaway tree with small .sh subjects that provoke SC2034/SC2155.
# SKIP_REAL_TREE=1 drops the live-tree case (what the mutation manifest runs with).
# docs/code-quality-tooling.md#shellcheck-warning-ratchet-shellcheck-warnings
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="${TESTS_DIR}/../verify_shellcheck_warnings.py"
LINT="${TESTS_DIR}/../lint-shell.sh"
PY="$(command -v "${PREFLIGHT_PYTHON:-python3}")"
TODAY="$(date +%F)"
PIN="$(sed -n 's/^SHELLCHECK_VERSION=//p' "${TESTS_DIR}/../01-core/versions.env")"
source "${TESTS_DIR}/test-harness.sh"

if ! command -v shellcheck >/dev/null 2>&1; then
  t_case "shellcheck is on PATH (the gate needs it, and so does this suite)"
  t_assert_ok command -v shellcheck
  t_summary
fi
SC_BIN="$(command -v shellcheck)"

# A tree whose linux/scripts holds one subject per `<name>:<shape>` argument.
# Shapes: unused (1x SC2034), unused2 (2x SC2034), masked (1x SC2155), clean,
# sourcer+sourced (a pair whose variable only looks unused without -x; the
# sourcer's directive names linux/scripts/lib.sh, so name the sibling `lib`).
_fixture() {
  local d spec name shape
  d="$(mktemp -d)"
  mkdir -p "${d}/linux/scripts" "${d}/linux/host-config" "${d}/linux/llm-stack" "${d}/linux/webserver"
  cp "${GATE}" "${TESTS_DIR}/../quality_allow.py" "${LINT}" "${d}/linux/scripts/"
  for spec in "$@"; do
    name="${spec%%:*}"; shape="${spec##*:}"
    case "${shape}" in
      unused)  printf '#!/usr/bin/env bash\nunused_a=1\n' ;;
      unused2) printf '#!/usr/bin/env bash\nunused_a=1\nunused_b=2\n' ;;
      masked)  printf '#!/usr/bin/env bash\nf() { local x="$(date)"; echo "${x}"; }\n' ;;
      sourcer) printf '#!/usr/bin/env bash\n# shellcheck source=linux/scripts/lib.sh\nsource "$(dirname "$0")/lib.sh"\nVAR=1\n' ;;
      sourced) printf '#!/usr/bin/env bash\necho "${VAR}"\n' ;;
      *)       printf '#!/usr/bin/env bash\necho ok\n' ;;
    esac > "${d}/linux/scripts/${name}.sh"
  done
  printf '%s' "${d}"
}
# A fake shellcheck that answers --version and prints the given json1 body verbatim.
_stub() {
  local d="$1"
  printf '%s' "$2" > "${d}/stub-payload"
  printf '#!/usr/bin/env bash\nif [ "$1" = "--version" ]; then printf "version: stub\\n"; exit 0; fi\ncat "%s"\n' \
    "${d}/stub-payload" > "${d}/stub-shellcheck"
  chmod +x "${d}/stub-shellcheck"
  printf '%s' "${d}/stub-shellcheck"
}
_freeze() { local d="$1"; shift; printf '%s\n' "$@" > "${d}/linux/scripts/shellcheck-warnings.allow"; }
_run() { local d="$1"; shift; t_out env "SHELLCHECK_BIN=${SC_BIN}" "${PY}" "${d}/linux/scripts/verify_shellcheck_warnings.py" "$@"; }
_rc()  { local d="$1"; shift; t_rc  env "SHELLCHECK_BIN=${SC_BIN}" "${PY}" "${d}/linux/scripts/verify_shellcheck_warnings.py" "$@"; }
_write() { _rc "$1" --write-baseline "${@:2}"; }
_rows() { grep -v -e '^#' "$1/linux/scripts/shellcheck-warnings.allow"; }
_head() { head -n "$2" "$1/linux/scripts/shellcheck-warnings.allow"; }
# The allow file as quality_allow.load_counts sees it — the reader other gates share.
_load_counts() {
  "${PY}" -c 'import sys; sys.path.insert(0, sys.argv[1]); from quality_allow import load_counts; print(sorted(load_counts(sys.argv[1] + "/shellcheck-warnings.allow").items()))' \
    "$1/linux/scripts"
}
ROW_A1="linux/scripts/a.sh | SC2034 | 1 | baseline"

# ── the fixtures really provoke what they claim ──────────────────────────────
t_case "the subject shapes provoke exactly the codes the suite relies on"
fix="$(_fixture a:unused m:masked)"
out="$(shellcheck -f gcc -S warning "${fix}/linux/scripts/a.sh" "${fix}/linux/scripts/m.sh" 2>&1)"
t_assert_contains "${out}" "SC2034" "a.sh must carry an unused variable"
t_assert_contains "${out}" "SC2155" "m.sh must carry a masked declaration"
rm -rf "${fix}"

# ── the four-way contract ────────────────────────────────────────────────────
t_case "a clean tree with no allow file passes"
fix="$(_fixture c:clean)"
t_assert_eq "0" "$(_rc "${fix}")"
t_assert_contains "$(_run "${fix}")" "match the baseline exactly"
rm -rf "${fix}"

t_case "a new (file, code) pair fails, names the allow file, and exits non-zero"
fix="$(_fixture a:unused)"
out="$(_run "${fix}")"
t_assert_eq "1" "$(_rc "${fix}")"
t_assert_contains "${out}" "linux/scripts/a.sh:SC2034 is 1 findings" "the pair and its count are named"
t_assert_contains "${out}" "not frozen" "an unfrozen pair must point at the allow file"
t_assert_contains "${out}" "shellcheck-warnings.allow"
rm -rf "${fix}"

t_case "a pair frozen at its recorded count passes"
fix="$(_fixture a:unused m:masked)"
_freeze "${fix}" "${ROW_A1}" "linux/scripts/m.sh | SC2155 | 1 | baseline"
t_assert_eq "0" "$(_rc "${fix}")"
rm -rf "${fix}"

t_case "a count above the frozen one fails as growth"
fix="$(_fixture a:unused2)"
_freeze "${fix}" "${ROW_A1}"
t_assert_eq "1" "$(_rc "${fix}")"
t_assert_contains "$(_run "${fix}")" "GREW from 1 to 2 findings"
rm -rf "${fix}"

t_case "a decrease is reported with the NEW count, so the improvement has to be recorded"
fix="$(_fixture a:unused)"
_freeze "${fix}" "linux/scripts/a.sh | SC2034 | 3 | baseline"
t_assert_eq "1" "$(_rc "${fix}")"
t_assert_contains "$(_run "${fix}")" "shrank from 3 to 1 findings"
rm -rf "${fix}"

t_case "a row whose pair no longer occurs is stale"
fix="$(_fixture a:clean)"
_freeze "${fix}" "${ROW_A1}"
t_assert_eq "1" "$(_rc "${fix}")"
t_assert_contains "$(_run "${fix}")" "STALE freeze for linux/scripts/a.sh:SC2034"
rm -rf "${fix}"

t_case "only warning-level findings count: a syntax error is lint-shell.sh's job"
fix="$(_fixture e:clean)"
printf '#!/usr/bin/env bash\nif true; then\n' > "${fix}/linux/scripts/e.sh"
t_assert_eq "0" "$(_rc "${fix}")" "SC1070/SC1073 are error-level and must not be ratcheted here"
rm -rf "${fix}"

# ── -x: a per-file run must see what the whole-set run sees ──────────────────
t_case "a variable consumed by a sourced sibling is unused in NEITHER mode"
fix="$(_fixture m:sourcer lib:sourced)"
t_assert_eq "0" "$(_rc "${fix}")" "the whole-set run follows the source= directive"
t_assert_eq "0" "$(_rc "${fix}" --files linux/scripts/m.sh)" \
  "and so must --files: without -x shellcheck only follows a directive whose target is also an input"
t_assert_eq "0" "$(_write "${fix}" --files linux/scripts/m.sh)"
t_assert_eq "0" "$(_rc "${fix}")" "--write-baseline --files must not write a row the whole-set run calls STALE"
rm -rf "${fix}"

t_case "--files reports only the listed files, whatever path the tool attributes a finding to"
fix="$(_fixture a:clean b:clean)"
stub="$(_stub "${fix}" '{"comments":[{"file":"linux/scripts/b.sh","line":1,"level":"warning","code":2034}]}')"
t_assert_eq "0" "$(SC_BIN="${stub}"; _rc "${fix}" --files linux/scripts/a.sh)" \
  "a finding attributed outside the listed set is not a.sh's problem"
t_assert_eq "1" "$(SC_BIN="${stub}"; _rc "${fix}")" "the whole-set run still sees it"
rm -rf "${fix}"

# ── --files: the staged-file mode of the pre-commit hook ─────────────────────
t_case "--files checks only the listed files: a change in an unlisted file is not reported"
fix="$(_fixture a:unused b:unused)"
_freeze "${fix}" "${ROW_A1}" "linux/scripts/b.sh | SC2034 | 1 | baseline"
printf 'g() { local y="$(id)"; echo "${y}"; }\n' >> "${fix}/linux/scripts/b.sh"
t_assert_eq "1" "$(_rc "${fix}")" "the full run sees b.sh's new SC2155"
t_assert_eq "0" "$(_rc "${fix}" --files linux/scripts/a.sh)" "a.sh alone is at its baseline"
out="$(_run "${fix}" --files "${fix}/linux/scripts/a.sh")"
t_assert_eq "0" "$(_rc "${fix}" --files "${fix}/linux/scripts/a.sh")" "absolute paths resolve too"
t_assert_contains "${out}" "(1 of 3 file(s))" "and resolve INTO the scope, rather than passing by being skipped"
t_assert_fails grep -q -F -e "note:" <<<"${out}"
t_assert_eq "1" "$(_rc "${fix}" --files linux/scripts/b.sh)" "b.sh alone is over its baseline"
t_assert_contains "$(_run "${fix}" --files linux/scripts/b.sh)" "b.sh:SC2155 is 1 findings"
rm -rf "${fix}"

t_case "--files on a file with zero rows and zero findings passes"
fix="$(_fixture a:unused c:clean)"
t_assert_eq "0" "$(_rc "${fix}" --files linux/scripts/c.sh)"
t_assert_contains "$(_run "${fix}" --files linux/scripts/c.sh)" "(1 of 3 file(s))" "the copied lint-shell.sh is in scope too"
rm -rf "${fix}"

t_case "--files on a file outside the lint-shell.sh scope is skipped with a note"
fix="$(_fixture c:clean)"
mkdir -p "${fix}/docs"; printf 'unused=1\n' > "${fix}/docs/x.sh"
out="$(_run "${fix}" --files docs/x.sh linux/scripts/gone.sh)"
t_assert_eq "0" "$(_rc "${fix}" --files docs/x.sh)"
t_assert_contains "${out}" "note: docs/x.sh is outside the lint-shell.sh scope, skipped"
t_assert_contains "${out}" "note: linux/scripts/gone.sh is outside" "a deleted file is outside too"
t_assert_contains "${out}" "(0 of 2 file(s))"
rm -rf "${fix}"

# ── --write-baseline: how a freeze and a recorded decrease are produced ──────
t_case "--write-baseline freezes the current counts with a dated, unreviewed reason"
fix="$(_fixture a:unused2 m:masked)"
t_assert_eq "0" "$(_write "${fix}")"
t_assert_eq "linux/scripts/a.sh | SC2034 | 2 | baseline ${TODAY}, not yet reviewed
linux/scripts/m.sh | SC2155 | 1 | baseline ${TODAY}, not yet reviewed" "$(_rows "${fix}")" "exact rows, sorted"
t_assert_contains "$(_head "${fix}" 2)" "# Format: <file> | SC<code> | <count> | <reason>" "the header is written"
t_assert_eq "0" "$(_rc "${fix}")" "the tree it just wrote passes"
rm -rf "${fix}"

t_case "--write-baseline keeps an existing reason, updates the count, and drops a stale row"
fix="$(_fixture a:unused2 m:clean)"
_freeze "${fix}" "# my header" "${ROW_A1/baseline/reviewed: keep me}" "linux/scripts/m.sh | SC2155 | 1 | gone"
t_assert_eq "0" "$(_write "${fix}")"
t_assert_eq "linux/scripts/a.sh | SC2034 | 2 | reviewed: keep me" "$(_rows "${fix}")" \
  "count 1 -> 2 with the reason kept; the m.sh row whose pair is gone is dropped"
t_assert_eq "# my header" "$(_head "${fix}" 1)" "the header comment survives a rewrite"
t_assert_eq "0" "$(_write "${fix}")" "a second write reads its own header (which contains |) back"
t_assert_eq "1" "$(_rows "${fix}" | wc -l)" "and does not turn a header line into a row"
rm -rf "${fix}"

t_case "--write-baseline --files rewrites only the listed file's rows"
fix="$(_fixture a:unused b:clean)"
_freeze "${fix}" "linux/scripts/a.sh | SC2034 | 5 | old" "linux/scripts/b.sh | SC2034 | 9 | untouched"
t_assert_eq "0" "$(_write "${fix}" --files linux/scripts/a.sh)"
t_assert_eq "linux/scripts/a.sh | SC2034 | 1 | old
linux/scripts/b.sh | SC2034 | 9 | untouched" "$(_rows "${fix}")" "a.sh re-counted with its reason kept; b.sh was not checked, so its row stays"
rm -rf "${fix}"

# ── the allow file is read the way quality_allow.load_counts reads it ────────
t_case "a reason carrying | or # is tolerated and normalised, so both readers agree"
fix="$(_fixture a:unused)"
_freeze "${fix}" "linux/scripts/a.sh | SC2034 | 1 | why | because   # side note"
t_assert_eq "0" "$(_rc "${fix}")" "the extra separators must not shift the count column"
t_assert_eq "0" "$(_write "${fix}")"
t_assert_eq "linux/scripts/a.sh | SC2034 | 1 | why because" "$(_rows "${fix}")" \
  "the rewritten reason carries neither separator"
t_assert_eq "[(('linux/scripts/a.sh', 'SC2034'), 1)]" "$(_load_counts "${fix}")" \
  "load_counts reads the same row back (it counts | -separated fields from the right)"
rm -rf "${fix}"

# ── the tool itself: never a silent zero ─────────────────────────────────────
t_case "a failing lint-shell.sh --list-files is exit 2, not an empty scope that passes"
fix="$(_fixture a:unused)"
printf '#!/usr/bin/env bash\nexit 1\n' > "${fix}/linux/scripts/lint-shell.sh"
t_assert_eq "2" "$(_rc "${fix}")"
t_assert_contains "$(_run "${fix}")" 'lint-shell.sh --list-files` failed'
rm -rf "${fix}"

t_case "shellcheck output that is not json1 is exit 2, not zero findings"
fix="$(_fixture a:unused)"
stub="$(_stub "${fix}" 'shellcheck: command failed')"
t_assert_eq "2" "$(SC_BIN="${stub}"; _rc "${fix}")"
t_assert_contains "$(SC_BIN="${stub}"; _run "${fix}")" "no json1 output"
rm -rf "${fix}"

t_case "no usable shellcheck is exit 2 with a clear message, and SHELLCHECK_BIN overrides"
fix="$(_fixture c:clean)"
bin="$(mktemp -d)"
for tool in bash dirname find sort head; do ln -s "$(command -v "${tool}")" "${bin}/${tool}"; done
out="$(env -u SHELLCHECK_BIN PATH="${bin}" "${PY}" "${fix}/linux/scripts/verify_shellcheck_warnings.py" 2>&1)"
rc="$(env -u SHELLCHECK_BIN PATH="${bin}" "${PY}" "${fix}/linux/scripts/verify_shellcheck_warnings.py" >/dev/null 2>&1; echo $?)"
t_assert_eq "2" "${rc}" "tool-missing is exit 2, never a silent pass"
t_assert_contains "${out}" "could not provide the pinned shellcheck"
t_assert_eq "0" "$(_rc "${fix}")" "SHELLCHECK_BIN names the binary explicitly"
rm -rf "${fix}" "${bin}"

# ── lint-shell.sh owns the binary, at the pinned version only ────────────────
_pin_probe() {  # --print-bin with $1 as the PATH shellcheck's version and $2 as the cache
  local d="$1" ver="$2" cache="$3"
  printf '#!/usr/bin/env bash\nprintf "version: %%s\\n" "%s"\n' "${ver}" > "${d}/shellcheck"
  chmod +x "${d}/shellcheck"
  env PATH="${d}:${PATH}" SHELLCHECK_CACHE_DIR="${cache}" bash "${LINT}" --print-bin 2>/dev/null
}
t_case "--print-bin rejects a PATH shellcheck that is not the pinned version"
stubdir="$(mktemp -d)"; cache="$(mktemp -d)"
mkdir -p "${cache}/shellcheck-${PIN}"; cp "${SC_BIN}" "${cache}/shellcheck-${PIN}/shellcheck"
t_assert_eq "${cache}/shellcheck-${PIN}/shellcheck" "$(_pin_probe "${stubdir}" "0.9.0" "${cache}")" \
  "CI's apt shellcheck disagrees with the frozen counts, so it must not win"
t_case "--print-bin uses a PATH shellcheck that IS the pinned version"
empty="$(mktemp -d)"
t_assert_eq "${stubdir}/shellcheck" "$(_pin_probe "${stubdir}" "${PIN#v}" "${empty}")" \
  "an empty cache means a wrong rejection would have to download, and print nothing"
rm -rf "${stubdir}" "${cache}" "${empty}"

t_case "--list-files prints a file list and nothing else, even when nothing matches"
work="$(mktemp -d)"; printf 'Just prose, not a script.\n' > "${work}/READMEISH"
t_assert_eq "" "$(bash "${LINT}" --list-files "${work}/READMEISH" 2>&1)" \
  "the 'no shell scripts to check' banner would become a bogus scope entry"
t_assert_contains "$(bash "${LINT}" --list-files 2>&1)" "linux/scripts/lint-shell.sh" "the real scope is non-empty"
printf '#!/usr/bin/env bash\r\n: "${X:-}"\r\n' > "${work}/crlfhook"
t_assert_contains "$(bash "${LINT}" --list-files "${work}/crlfhook" 2>&1)" "crlfhook" \
  "a CRLF extension-less script must still classify as shell, or it is invisible to this gate AND to crlf-guard"
rm -rf "${work}"

# ── the real tree ────────────────────────────────────────────────────────────
if [ -z "${SKIP_REAL_TREE:-}" ]; then
  t_case "the REAL tree matches its baseline today"
  t_assert_eq "0" "$("${PY}" "${GATE}" >/dev/null 2>&1; echo $?)"
fi

t_summary
