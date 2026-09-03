#!/usr/bin/env bash
# Tests for the allowlist contract of verify_code_dupes.py. The gate derives its
# root from its own path, so each case copies it into a throwaway tree holding two
# scripts that share one function; the measured overlap is parsed, never hardcoded.
# docs/code-quality-tooling.md#contract-tightening-2026-09-03-code-dupes-env-knobs
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
GATE="$(cd "${TESTS_DIR}/../../.." && pwd)/docs/scripts/verify_code_dupes.py"
PY="${PREFLIGHT_PYTHON:-python3}"
A="linux/scripts/a.sh"
B="linux/scripts/b.sh"
C="linux/scripts/c.sh"
WHY="reviewed 2026-09-03 — kept on purpose; budget pinned"

_twin() {
  cat <<'EOF'
#!/usr/bin/env bash
probe_widget() {
  local target="$1" mode="$2"
  if [ ! -d "${target}/lib" ]; then
    echo "missing lib under ${target}" >&2
    return 1
  fi
  case "${mode}" in
    fast) ls "${target}/lib" | head -n 3 ;;
    slow) find "${target}/lib" -type f -name '*.so' | sort ;;
    *) echo "unknown mode ${mode}" >&2; return 2 ;;
  esac
  printf 'probed %s in %s mode\n' "${target}" "${mode}"
}
EOF
}

# A tree with the gate at its real depth, a.sh/b.sh holding a renamed copy of one
# function, and the allow rows given as arguments (none = no allow file).
_fixture() {
  fix="$(mktemp -d)"
  mkdir -p "${fix}/docs/scripts" "${fix}/linux/scripts"
  cp "${GATE}" "${fix}/docs/scripts/"
  _twin > "${fix}/${A}"
  _twin | sed 's/probe_widget/probe_gadget/' > "${fix}/${B}"
  [ $# -gt 0 ] && printf '%s\n' "$@" > "${fix}/docs/scripts/code-dupes.allow"
  return 0
}
_gate() { "${PY}" "${fix}/docs/scripts/verify_code_dupes.py" "$@"; }
_allow() { cat "${fix}/docs/scripts/code-dupes.allow"; }
# Run the gate on the current fixture; leaves rc and out behind for the asserts.
_verdict() { out="$(_gate "$@" 2>&1)"; rc=$?; }
# Build from the given rows, run, tear down.
_check() { _fixture "$@"; _verdict; rm -rf "${fix}"; }

t_case "an unlisted twin fails, and actually exits non-zero"
_check
N="$(printf '%s\n' "${out}" | sed -nE 's/^  ([0-9]+) shared shingles.*/\1/p' | head -1)"
t_assert_contains "${out}" "1 copied block(s)" "a renamed copy is still a copy"
t_assert_eq "1" "${rc}" "printing a finding is not enough; it must fail"
t_assert_ok test "${N:-0}" -gt 10

t_case "a row at exactly the measured budget passes"
_check "${A} | ${B} | ${N} | ${WHY}"
t_assert_eq "0" "${rc}" "the baseline is the contract"
t_assert_contains "${out}" "1 allowlisted pair(s)"

t_case "the pair key is unordered: b | a matches a | b"
_check "${B} | ${A} | ${N} | ${WHY}"
t_assert_eq "0" "${rc}" "swapping the columns must not read as a new offender"

t_case "a shrunk budget fails and names the new budget with the exact row to paste"
_check "${A} | ${B} | $((N + 3)) | ${WHY}"
t_assert_eq "1" "${rc}" "slack in a budget is where regrowth hides"
t_assert_contains "${out}" "shrank from $((N + 3)) to ${N}"
t_assert_contains "${out}" "record the new budget ${N}"
t_assert_contains "${out}" "${A} | ${B} | ${N} | ${WHY}" "the reason must survive verbatim"

t_case "growth past the budget fails"
_check "${A} | ${B} | $((N - 1)) | ${WHY}"
t_assert_eq "1" "${rc}"
t_assert_contains "${out}" "over its budget of $((N - 1))"

t_case "a row whose pair no longer overlaps is stale, and is reported beside a shrink"
_check "${A} | ${B} | $((N + 1)) | ${WHY}" "${A} | linux/scripts/gone.sh | 20 | ${WHY}"
t_assert_eq "1" "${rc}"
t_assert_contains "${out}" "1 stale allowlist entr(ies)"
t_assert_contains "${out}" "linux/scripts/gone.sh is no longer over the threshold (0 shared"
t_assert_contains "${out}" "shrank from $((N + 1)) to ${N}" "both bookkeeping errors in one run"

t_case "a pair that dropped UNDER the threshold reports its real count, not 'no overlap'"
_fixture "${A} | ${B} | ${N} | ${WHY}"
_verdict --threshold $((N + 5))
t_assert_eq "1" "${rc}" "under the threshold is still a stale row"
t_assert_contains "${out}" "is no longer over the threshold (${N} shared, threshold $((N + 5)))"
rm -rf "${fix}"

t_case "the same pair listed twice is a bookkeeping error naming both rows"
_check "${A} | ${B} | ${N} | ${WHY}" "${B} | ${A} | $((N + 4)) | second copy"
t_assert_eq "2" "${rc}" "last-wins would silently pick one of two budgets"
t_assert_contains "${out}" "code-dupes.allow:2: duplicate row"
t_assert_contains "${out}" "(first at line 1)"

t_case "--kind judges only that kind's rows: a shell pair is not stale under --kind docker"
_fixture "${A} | ${B} | ${N} | ${WHY}"
printf 'FROM scratch\nRUN true\n' > "${fix}/linux/Dockerfile.probe"
_verdict --kind docker
t_assert_eq "0" "${rc}" "out of scope is not stale"
_verdict --kind shell
t_assert_eq "0" "${rc}"
rm -rf "${fix}"

t_case "a shrunk budget still prints when a new finding also fails the run"
_fixture "${A} | ${B} | $((N + 3)) | ${WHY}"
_twin | sed 's/probe_widget/probe_gizmo/' > "${fix}/${C}"
_verdict
t_assert_eq "1" "${rc}"
t_assert_contains "${out}" "copied block(s)" "the unlisted third twin is a finding"
t_assert_contains "${out}" "shrank from $((N + 3)) to ${N}" "bookkeeping must not hide behind a finding"
rm -rf "${fix}"

t_case "a same-file twin is keyed on one name written twice"
_fixture "${C} | ${C} | ${N} | ${WHY}"
cat "${fix}/${A}" "${fix}/${B}" > "${fix}/${C}"; rm -f "${fix}/${A}" "${fix}/${B}"
_verdict
t_assert_eq "0" "${rc}" "exact budget passes for a same-file pair"
printf '%s\n' "${C} | ${C} | $((N + 2)) | ${WHY}" > "${fix}/docs/scripts/code-dupes.allow"
_verdict
t_assert_contains "${out}" "${C} | ${C} | ${N} | ${WHY}" "the pasteable row repeats the name"
rm -rf "${fix}"

t_case "--baseline writes the measurement and keeps an existing reason verbatim"
_fixture "${A} | ${B} | $((N + 3)) | ${WHY}"
_verdict --baseline
t_assert_eq "0" "${rc}"
t_assert_contains "$(_allow)" "${A} | ${B} | ${N} | ${WHY}"
_verdict
t_assert_eq "0" "${rc}" "a fresh baseline is green"
rm -rf "${fix}"

t_case "--baseline dates a NEW row with today's date"
_fixture
_verdict --baseline
t_assert_eq "0" "${rc}"
t_assert_contains "$(_allow)" "${A} | ${B} | ${N} | baseline $(date +%F), not yet reviewed"
rm -rf "${fix}"

t_case "the REAL tree is clean today"
t_assert_eq "0" "$(t_rc "${PY}" "${GATE}")"

t_summary
