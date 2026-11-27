#!/usr/bin/env bash
# verify_code_dupes.py's allowlist; SKIP_REAL_TREE=1 skips the live tree. See docs/code-quality-tooling.md#contract-tightening-2026-09-03-code-dupes-env-knobs
set -u
: "${SKIP_REAL_TREE:=}"
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
source "${TESTS_DIR}/gate-tree.sh"
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

# The <# #> block's unbalanced brace and the blank line are where a mis-reading scanner would split.
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

# The copy, renamed; $2=nextline moves the brace to its own line, which must measure the same.
_ps_copy() {
  _ps_twin "$1" | sed -e 's/Resolve-Widget/Resolve-Gadget/' \
                      -e "$([ "$2" = nextline ] && printf '%s' 's/^function Resolve-Gadget {$/function Resolve-Gadget\n{/' || printf 'b')"
}

# _ps_pair <var-a> <var-b> <brace style> [sed for both]: the PowerShell pair, into the fixture.
_ps_pair() {
  mkdir -p "${fix}/windows/scripts"
  _ps_twin "$1" | sed "${4:-b}" > "${fix}/${P}"
  _ps_copy "$2" "$3" | sed "${4:-b}" > "${fix}/${Q}"
}
# The shingle count the gate reports for the single finding it just printed.
_shared() { printf '%s\n' "${out}" | sed -nE 's/^  ([0-9]+) shared shingles.*/\1/p' | head -1; }
# Build a fixture holding only the PowerShell pair as an offender, run, tear down.
_ps_verdict() { _fixture "${A} | ${B} | ${N} | ${WHY}"; _ps_pair "$@"; _verdict; }

# _fixture [allow-row...]: the gate at its real depth and one renamed function copy in a.sh/b.sh.
_fixture() {
  fix="$(mktemp -d)"
  mkdir -p "${fix}/docs/scripts" "${fix}/linux/scripts"
  cp "${GATE}" "${GATE%/*}/code_dupes_ps.py" "${fix}/docs/scripts/"
  # The gate imports gate_scope.py at module level; without it the fixture tracebacks.
  cp "${SCRIPTS_DIR}/quality_allow.py" "${SCRIPTS_DIR}/gate_scope.py" \
    "${SCRIPTS_DIR}/verify_code_size.py" "${fix}/linux/scripts/"
  _twin > "${fix}/${A}"
  _twin | sed 's/probe_widget/probe_gadget/' > "${fix}/${B}"
  [ $# -gt 0 ] && printf '%s\n' "$@" > "${fix}/docs/scripts/code-dupes.allow"
  return 0
}
_gate() { "${PY}" "${fix}/docs/scripts/verify_code_dupes.py" "$@"; }
_allow() { cat "${fix}/docs/scripts/code-dupes.allow"; }
_shell_units() {
  "${PY}" - "${fix}/docs/scripts/verify_code_dupes.py" "$1" <<'PY'
import importlib.util
import sys
from pathlib import Path

spec = importlib.util.spec_from_file_location("dupes", sys.argv[1])
dupes = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = dupes
spec.loader.exec_module(dupes)
units = dupes.shell_units(Path(sys.argv[2]))
print(f"{len(units)}|{units[-1][1].splitlines()[0]}")
PY
}
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

t_case "a quoted shell brace cannot absorb the following function"
_fixture
cat > "${fix}/${A}" <<'EOF'
brace_literal() {
  local pattern='${'
  printf '%s\n' "${pattern}"
}
following_function() {
  printf 'kept separate\n'
}
EOF
units="$(_shell_units "${fix}/${A}")"
t_assert_eq "2|following_function() {" "${units}"
rm -rf "${fix}"

t_case "the pair key is unordered: b | a matches a | b"
_check "${B} | ${A} | ${N} | ${WHY}"
t_assert_eq "0" "${rc}" "swapping the columns must not read as a new offender"

t_case "--explain reports the same overlap in either file order"
_fixture "${A} | ${B} | ${N} | ${WHY}"
_verdict --explain "${A}" "${B}"
t_assert_eq 0 "${rc}"
t_assert_contains "${out}" " ${N} shingle(s)" "the forward report must expose the measured twin"
_verdict --explain "${B}" "${A}"
t_assert_eq 0 "${rc}"
t_assert_contains "${out}" " ${N} shingle(s)" "reversed inputs must not claim that a real copy shares nothing"
t_assert_contains "${out}" "${B} <-> ${A}" "report labels retain the requested orientation"
rm -rf "${fix}"

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
_verdict --explain "${C}"
t_assert_eq 0 "${rc}"
t_assert_contains "${out}" " ${N} shingle(s)" "self comparisons still count each twin only once"
t_assert_eq 1 "$(printf '%s\n' "${out}" | grep -cE '^[[:space:]]+[0-9]+ shingle[(]s[)]')" "no unit may be compared with itself or repeated in reverse"
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

# The reference measurement every ps case compares against: a renamed copy written the same way.
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

# The measurement must not move: a mis-read block is usually still a finding, just a smaller one.
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

t_case "regex, comment and here-string braces do not absorb later PowerShell functions"
_fixture
mkdir -p "${fix}/windows/scripts"
cat > "${fix}/${P}" <<'EOF'
function Read-Lock {
  $pattern = 'sdist = \{ url = "(?<url>[^\"]+)", hash = "sha256:(?<sha>[0-9a-f]{64})'
  $shim = @'
if value:
    print('{')
'@ + 'tail'
  # { is not part of the function body
}
function Stop-NextUnit {
  return $true
}
EOF
units="$(${PY} -c 'import importlib.util,sys; from pathlib import Path; sys.path.insert(0,str(Path(sys.argv[1]).parent)); s=importlib.util.spec_from_file_location("dupes",sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); u=m.ps_units(Path(sys.argv[2])); print("{}|{}".format(len(u), "function Stop-NextUnit" in u[0][1]))' "${GATE}" "${fix}/${P}")"
t_assert_eq "2|False" "${units}" "literal braces stay out of the function-depth count"
rm -rf "${fix}"

t_case "a Pester suite named Dockerfile.*.ps1 is PowerShell, not a Dockerfile"
_ps_verdict '$WidgetStrict' '$GadgetStrict' same
mv "${fix}/${Q}" "${fix}/${R}"
_verdict
t_assert_eq "1" "${rc}" "the extension decides, not the prefix"
t_assert_contains "${out}" "${R}"
rm -rf "${fix}"

# Six parameters, long enough that the block alone would be a finding if it counted.
PS_PARAMS="$(cat <<'EOF'
  param(
    [Parameter(Mandatory)][pscustomobject]$Context,
    [Parameter(Mandatory)][string]$BuildRoot,
    [ValidateSet('Debug', 'Release')][string]$Config = 'Debug',
    [string[]]$Targets = @('engine', 'tests'),
    [switch]$StageTestPlugins,
    [switch]$CopyOrtBeside
  )
EOF
)"
PS_OTHER_PARAMS='  param([string]$Root, [int]$Depth = 3)'
PS_BODY_A="$(cat <<'EOF'
  $bin = Join-Path $BuildRoot 'bin'
  New-Item -ItemType Directory -Force -Path $bin | Out-Null
  Write-BuildLog -Context $Context -Message "staged $Config into $bin"
EOF
)"
PS_BODY_B="$(cat <<'EOF'
  foreach ($target in $Targets) {
    Invoke-Native -FilePath 'cmake' -ArgumentList @('--build', $BuildRoot, '--target', $target)
  }
  if ($StageTestPlugins) { Copy-TestPlugin -Root $BuildRoot }
EOF
)"
PS_BODY_DUP="$(cat <<'EOF'
  if (-not (Test-Path -LiteralPath $BuildRoot)) {
    throw "no build root at $BuildRoot"
  }
  $found = @(Get-ChildItem -LiteralPath $BuildRoot -Recurse -Filter '*.dll' | Sort-Object Name)
  foreach ($item in $found) {
    Write-Host "found $($item.FullName) for $Config"
  }
  return $found
EOF
)"
# _ps_fn <name> <param block> <body>: one PowerShell function.
_ps_fn() { printf 'function %s {\n%s\n%s\n}\n' "$1" "$2" "$3"; }
# _ps_files <P text> <Q text>: a fixture whose only offender can be the PowerShell pair.
_ps_files() {
  _fixture "${A} | ${B} | ${N} | ${WHY}"
  mkdir -p "${fix}/windows/scripts"
  printf '%s\n' "$1" > "${fix}/${P}"
  printf '%s\n' "$2" > "${fix}/${Q}"
}
# _ps_fns <P params> <P body> <Q params> <Q body> [gate args]: two renamed functions, judged; leaves rc and out.
_ps_fns() {
  _ps_files "$(_ps_fn Copy-Widget "$1" "$2")" "$(_ps_fn Copy-Gadget "$3" "$4")"
  shift 4
  _verdict "$@"
}
# The first counted unit pair --explain prints, 0 when only idiom is shared.
_explained() { printf '%s\n' "${out}" | sed -nE 's/^ +([0-9]+) shingle\(s\)  line .*/\1/p' | head -1 | grep -e . || echo 0; }
# What --explain dropped as idiom from a pair that counts nothing.
_idiom_only() { printf '%s\n' "${out}" | sed -nE 's/^  ([0-9]+) further shingle\(s\).*/\1/p' | head -1; }

t_case "two functions sharing only an identical param block pass: the block is idiom"
_ps_fns "${PS_PARAMS}" "${PS_BODY_A}" "${PS_PARAMS}" "${PS_BODY_B}"
t_assert_eq "0" "${rc}" "a shared parameter list is the language's shape, not a copy"
_verdict --explain "${P}" "${Q}"
t_assert_eq "0" "$(_explained)" "nothing counted between the two"
t_assert_ok test "$(_idiom_only)" -gt 10
rm -rf "${fix}"

t_case "identical bodies behind different param blocks are still a copy"
_ps_fns "${PS_PARAMS}" "${PS_BODY_DUP}" "${PS_OTHER_PARAMS}" "${PS_BODY_DUP}"
PARAM_N="$(_shared)"
t_assert_eq "1" "${rc}" "the body after the block is still compared"
t_assert_contains "${out}" "${Q}"
t_assert_ok test "${PARAM_N:-0}" -gt 10
rm -rf "${fix}"

t_case "a shared param block before a copied body adds nothing to its count"
_ps_fns "${PS_PARAMS}" "${PS_BODY_DUP}" "${PS_PARAMS}" "${PS_BODY_DUP}"
t_assert_eq "1" "${rc}" "a copy behind a twin header still fails"
t_assert_eq "${PARAM_N}" "$(_shared)" "the block neither forms nor extends a counted shingle"
rm -rf "${fix}"

t_case "a script-level param block with blank lines and comments is idiom too"
# The same parameters with a blank line and a comment mid-block, which splits it across two loose chunks.
_ps_script() {
  printf '[CmdletBinding()]\n'
  printf '%s\n' "${PS_PARAMS}" | sed -e 's/^  //' -e '/ValidateSet/s/,$/,\n\n    # a comment line between parameters/'
  printf '\n%s\n' "$1"
}
_ps_files "$(_ps_script "${PS_BODY_A}")" "$(_ps_script "${PS_BODY_B}")"
_verdict
t_assert_eq "0" "${rc}" "a block split across units is still found on the whole file"
_verdict --explain "${P}" "${Q}"
t_assert_ok test "$(_idiom_only)" -gt 10
rm -rf "${fix}"

t_case "a paren inside a param block's string or comment does not end the block"
EARLY_CLOSE="  param([string]\$Close = ')', # ( opens nothing
${PS_PARAMS#*param(}"
_ps_fns "${EARLY_CLOSE}" "${PS_BODY_A}" "${EARLY_CLOSE}" "${PS_BODY_B}"
t_assert_eq "0" "${rc}" "a literal paren closing the block early would count the rest of it"
rm -rf "${fix}"

t_case "-Param ( and .Param( in a body are calls, not param blocks"
_ps_calls() {
  cat <<EOF
  \$builder = New-Builder -Name \$Name
  \$builder.$1('mode', \$Mode)
  \$builder.$1('jobs', \$Jobs)
  Set-BuildOption -$1 (\$Mode) -Value (\$Jobs)
  Set-BuildOption -$1 (\$Jobs) -Value (\$Mode)
  return \$builder.Build()
EOF
}
_ps_fns "" "$(_ps_calls Knob)" "" "$(_ps_calls Knob)"
KNOB_N="$(_shared)"
t_assert_eq "1" "${rc}"
rm -rf "${fix}"
_ps_fns "" "$(_ps_calls Param)" "" "$(_ps_calls Param)"
t_assert_eq "1" "${rc}" "a method or argument named Param is still code"
t_assert_eq "${KNOB_N}" "$(_shared)" "renaming Param to Knob must not move the count"
rm -rf "${fix}"

t_case "a shared run ending at a param block is not extended into it"
_ps_visitor() {
  printf '%s\n' '$ast = Get-TestScriptAst -ScriptPath $ScriptPath' "\$calls = @(\$ast.FindAll({ $1" "$2" '        }, $true))'
}
P_BODY='            $node -is [System.Management.Automation.Language.CommandAst] -and $recurse'
Q_BODY='            Write-Verbose "visiting $node"; $node.Extent.Text.Length -gt 80'
_ps_files "$(_ps_visitor 'param($node, $recurse)' "${P_BODY}")" "$(_ps_visitor 'param($node, $recurse)' "${Q_BODY}")"
_verdict --explain "${P}" "${Q}"
SAME_N="$(_explained)"
rm -rf "${fix}"
_ps_files "$(_ps_visitor 'param($node, $recurse)' "${P_BODY}")" "$(_ps_visitor 'param([string]$node)' "${Q_BODY}")"
_verdict --explain "${P}" "${Q}"
t_assert_ok test "${SAME_N}" -gt 0
t_assert_eq "$(_explained)" "${SAME_N}" "a twin param block must not lengthen the run before it"
rm -rf "${fix}"

t_case "a param block still counts toward the idiom census"
INLINE="([string[]]\$Names = @(), [string]\$Label = '', [switch]\$Force, [int]\$Depth = 3)"
_ps_inline_pair() {
  _ps_files "function Copy-Widget${INLINE} {
${PS_BODY_A}
}" "function Copy-Gadget${INLINE} {
${PS_BODY_B}
}"
}
_ps_inline_pair
_verdict --explain "${P}" "${Q}"
ALONE_N="$(_explained)"
t_assert_ok test "${ALONE_N}" -gt 10
rm -rf "${fix}"
_ps_inline_pair
for i in 1 2 3 4 5 6 7; do
  _ps_fn "Get-Census${i}" "  param${INLINE}" "  Write-Output 'census ${i} of seven'" > "${fix}/windows/scripts/Get-Census${i}.ps1"
done
_verdict --explain "${P}" "${Q}"
t_assert_ok test "$(_explained)" -lt "${ALONE_N}"
rm -rf "${fix}"

t_case "a param mark lost inside a folded string cannot leak past its line"
touched="$(${PY} -c 'import sys; from pathlib import Path; sys.path.insert(0,str(Path(sys.argv[1]).parent)); import code_dupes_ps as m; print(sorted(m.strip_param_marks([m.PARAM_OPEN + " x", "y z"], 12)[1]))' "${GATE}")"
t_assert_eq "[0]" "${touched}" "an open mark whose close was folded into a string ends with its line"

if [ -z "${SKIP_REAL_TREE}" ]; then
  t_case "the REAL tree is clean today"
  t_assert_eq "0" "$(t_rc "${PY}" "${GATE}")"
fi

# The --root arm: a second checkout with its own twin pair and its own budget.
t_case "--root grades the named tree, and its budget lives under that root"
gate_root_pair_arm "${PY}" "${GATE}" "$(_twin)" scripts/a.sh scripts/b.sh code-dupes.allow

t_case "--allow-empty accepts only an empty supported scope, not a broken root or a finding"
t_assert_rc 0 "${PY}" "${TESTS_DIR}/code_dupes_options_tests.py" "${GATE}" "$(_twin)"

t_summary
