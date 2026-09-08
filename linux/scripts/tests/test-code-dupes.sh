#!/usr/bin/env bash
# Tests for the allowlist contract of verify_code_dupes.py. The gate derives its
# root from its own path, so each case copies it into a throwaway tree holding two
# scripts that share one function; the measured overlap is parsed, never hardcoded.
# SKIP_REAL_TREE=1 drops the live-tree case (what the mutation manifest runs with).
# docs/code-quality-tooling.md#contract-tightening-2026-09-03-code-dupes-env-knobs
set -u
: "${SKIP_REAL_TREE:=}"
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
GATE="$(cd "${TESTS_DIR}/../../.." && pwd)/docs/scripts/verify_code_dupes.py"
SCRIPTS_DIR="$(cd "${TESTS_DIR}/.." && pwd)"
PY="${PREFLIGHT_PYTHON:-python3}"
A="linux/scripts/a.sh"
B="linux/scripts/b.sh"
C="linux/scripts/c.sh"
P="windows/scripts/Resolve-Widget.ps1"
Q="windows/scripts/Resolve-Gadget.psm1"
R="windows/scripts/Dockerfile.Widget.Tests.ps1"
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

# One PowerShell function, with the strict-mode arm reading whatever variable $1
# names: a pair built from two calls differs in exactly the spelling under test.
# The <# #> block holds an unbalanced brace on purpose, and the body carries a
# blank line — together they are what a reader that mis-reads either construct
# splits this one function into, and every ps case below measures that.
_ps_twin() {
  cat <<EOF
Set-StrictMode -Version Latest

function Resolve-Widget {
  param([string]\$Root, [string]\$Mode)
  <#
    Deliberately unbalanced: } and { inside a comment.
  #>
  if (-not (Test-Path -LiteralPath \$Root)) {
    throw "no root at \$Root"
  }

  \$found = @(Get-ChildItem -LiteralPath \$Root -Recurse -Filter '*.dll' | Sort-Object Name)
  foreach (\$item in \$found) {
    Write-Host "found \$(\$item.FullName) for \$Mode"
  }
  if ($1 -and \$found.Count -eq 0) {
    throw "nothing under \$Root"
  }
  return \$found
}
EOF
}

# The copy, renamed. $2 = "nextline" moves its opening brace onto its own line;
# PowerShell allows both spellings and the two must measure the same.
_ps_copy() {
  _ps_twin "$1" | sed -e 's/Resolve-Widget/Resolve-Gadget/' \
                      -e "$([ "$2" = nextline ] && printf '%s' 's/^function Resolve-Gadget {$/function Resolve-Gadget\n{/' || printf 'b')"
}

# Adds the PowerShell pair to the current fixture. $1/$2 are the variables the
# two copies disagree on, $3 the copy's brace style, $4 a sed applied to BOTH.
_ps_pair() {
  mkdir -p "${fix}/windows/scripts"
  _ps_twin "$1" | sed "${4:-b}" > "${fix}/${P}"
  _ps_copy "$2" "$3" | sed "${4:-b}" > "${fix}/${Q}"
}
# The shingle count the gate reports for the single finding it just printed.
_shared() { printf '%s\n' "${out}" | sed -nE 's/^  ([0-9]+) shared shingles.*/\1/p' | head -1; }
# Build a fixture holding only the PowerShell pair as an offender, run, tear down.
_ps_verdict() { _fixture "${A} | ${B} | ${N} | ${WHY}"; _ps_pair "$@"; _verdict; }

# A tree with the gate at its real depth, a.sh/b.sh holding a renamed copy of one
# function, and the allow rows given as arguments (none = no allow file).
_fixture() {
  fix="$(mktemp -d)"
  mkdir -p "${fix}/docs/scripts" "${fix}/linux/scripts"
  cp "${GATE}" "${fix}/docs/scripts/"
  cp "${SCRIPTS_DIR}/quality_allow.py" "${fix}/linux/scripts/"
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
N="$(_shared)"
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

t_case "the shared reader parses the rows: a | or a # in the reason is reason text"
_check "${A} | ${B} | ${N} | ${WHY} | 12 | and a tail"
t_assert_eq "0" "${rc}" "the key arity is declared as 2, so the budget is column 3"
_check "${A} | ${B} | ${N} | ${WHY} # not a comment"
t_assert_eq "0" "${rc}" "only a row that STARTS with # is a comment"

t_case "a malformed row is a message naming file and line, never a traceback"
_check "${A} | ${B} | ${WHY}"
t_assert_eq "2" "${rc}"
t_assert_contains "${out}" "code-dupes.allow:1: expected 'a | b | budget | reason'"
t_assert_eq "" "$(printf '%s' "${out}" | grep -e Traceback || true)" "a gate error, not a crash"

t_case "two IDENTICAL rows are caught too, not silently folded into one"
_check "${A} | ${B} | ${N} | ${WHY}" "${A} | ${B} | ${N} | ${WHY}"
t_assert_eq "2" "${rc}" "keying the reader by row would drop the repeat before the check saw it"
t_assert_contains "${out}" "code-dupes.allow:2: duplicate row"

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

t_case "--baseline is refused with --kind: a scoped rewrite would drop other kinds"
_fixture "${A} | ${B} | ${N} | ${WHY}" "linux/Dockerfile.probe | linux/Dockerfile.other | 40 | ${WHY}"
_verdict --baseline --kind shell
t_assert_eq "2" "${rc}" "a scoped baseline must refuse, not rewrite"
t_assert_contains "${out}" "not allowed with argument --baseline"
t_assert_contains "$(_allow)" "linux/Dockerfile.probe" "the other kind's row must survive untouched"
t_assert_contains "$(_allow)" "${A} | ${B} | ${N}" "and so must the kind it WAS given"
rm -rf "${fix}"

# The reference measurement every ps case compares against: one function, copied
# and renamed, both copies written the same way. 50,862 lines of PowerShell were
# scanned by no structural gate at all, which is what made the Build-Windows.ps1
# and Resolve-BuildModule.ps1 families free to drift.
t_case "PowerShell under windows/ is in scope: a renamed .psm1 copy is a copy"
_ps_verdict '$WidgetStrict' '$GadgetStrict' same
PS_N="$(_shared)"
t_assert_eq "1" "${rc}" "a lane the gate cannot read is a lane it cannot guard"
t_assert_contains "${out}" "1 copied block(s)" "the shell pair is allowed; the PowerShell one is not"
t_assert_contains "${out}" "${Q}" "the .psm1 copy must be named"
t_assert_ok test "${PS_N:-0}" -gt 10
rm -rf "${fix}"

t_case "the PowerShell pair freezes and ratchets like every other kind"
_fixture "${A} | ${B} | ${N} | ${WHY}" "${P} | ${Q} | ${PS_N} | ${WHY}"
_ps_pair '$WidgetStrict' '$GadgetStrict' same
_verdict
t_assert_eq "0" "${rc}" "a budget EQUAL to the measurement is the freeze"
_verdict --kind ps
t_assert_eq "0" "${rc}" "and ps is a kind of its own"
rm -rf "${fix}"

# The next three all say the same thing in the only way that cannot go vacuous:
# change one spelling, and the MEASUREMENT must not move. Asserting "still a
# finding" proved nothing — a mis-read block is usually still a finding, just a
# smaller one, and two of these tests passed with their guarantee removed until
# they were written this way.
t_case "the opening brace may sit on the next line: both spellings measure the same"
_ps_verdict '$WidgetStrict' '$GadgetStrict' nextline
t_assert_eq "${PS_N}" "$(_shared)" "a function header PowerShell accepts, the gate must too"
rm -rf "${fix}"

t_case "a scope qualifier is part of the variable: \$env:X reads as \$V, not \$V : X"
_ps_verdict '$env:WidgetStrict' '$script:GadgetStrict' same
t_assert_eq "${PS_N}" "$(_shared)" "the same block scope-qualified must measure the same"
rm -rf "${fix}"

t_case "a <# #> comment is blanked, braces and all: the function stays one unit"
_ps_verdict '$WidgetStrict' '$GadgetStrict' same '/<#/,/#>/d'
t_assert_eq "${PS_N}" "$(_shared)" "dropping the comment must not change what is measured"
rm -rf "${fix}"

t_case "a Pester suite named Dockerfile.*.ps1 is PowerShell, not a Dockerfile"
_ps_verdict '$WidgetStrict' '$GadgetStrict' same
mv "${fix}/${Q}" "${fix}/${R}"
_verdict
t_assert_eq "1" "${rc}" "the extension decides, not the prefix"
t_assert_contains "${out}" "${R}"
rm -rf "${fix}"

if [ -z "${SKIP_REAL_TREE}" ]; then
  t_case "the REAL tree is clean today"
  t_assert_eq "0" "$(t_rc "${PY}" "${GATE}")"
fi

t_summary
