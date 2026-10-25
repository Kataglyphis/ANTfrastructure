#!/usr/bin/env bash
# Fixture roots isolate hub and consumer lint verdicts; see docs/code-quality-tooling.md#proving-a-gate-can-go-red.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
S="$(cd "${TESTS_DIR}/.." && pwd)"
PIN="$(sed -n 's/^RUFF_VERSION=//p' "${S}/01-core/tool-pins.env")"

if ! command -v ruff >/dev/null 2>&1 && ! command -v uvx >/dev/null 2>&1; then
  t_case "ruff or uvx is on PATH (the gate bootstraps from one, and so does this suite)"
  t_assert_ok command -v uvx
  t_summary
fi

# A complete fixture keeps extractor failures separate from Ruff verdicts.
_mkroot() {
  local d
  d="$(mktemp -d)"
  mkdir -p "${d}/linux/scripts/01-core" "${d}/docs/scripts" \
           "${d}/linux/host-config/git-hooks"
  cp "${S}/lint-python.sh" "${S}/extract_embedded_python.py" "${d}/linux/scripts/"
  # The gate sources these 01-core files; without them every case fails on a missing source.
  cp "${S}/01-core/load-versions-env.sh" "${S}/01-core/lint-root.sh" "${S}/01-core/lint-scope-init.sh" \
     "${S}/01-core/python-probe.sh" \
     "${d}/linux/scripts/01-core/"
  printf 'RUFF_VERSION=%s\n' "${PIN}" > "${d}/linux/scripts/01-core/tool-pins.env"
  printf '%s\n' "${d}"
}

# _run <root> [targets...] -> the gate's output plus `rc=<n>`; consumes the root.
_run() {
  local out rc
  local root="$1"; shift
  out="$(bash "${root}/linux/scripts/lint-python.sh" "$@" 2>&1)"; rc=$?
  rm -rf "${root}"
  printf '%s\nrc=%s\n' "${out}" "${rc}"
}

# _lint <subject.py body> -> the gate's output plus `rc=<n>`
_lint() {
  local d
  d="$(_mkroot)"
  printf '%s\n' "$1" > "${d}/docs/scripts/subject.py"
  _run "${d}" "${d}/docs/scripts/subject.py"
}

# _targets <subject.py> <heredoc py> [hook heredoc py]: every target shape; openers are printf args, so this suite is not extracted.
_targets() {
  local d
  d="$(_mkroot)"
  printf '%s\n' "$1" > "${d}/docs/scripts/subject.py"
  { printf 'probe() {\n'
    printf '  python3 - %s\n' "<<'PY'"
    printf '%s\nPY\n}\n' "$2"
  } > "${d}/linux/scripts/probe.sh"
  { printf '#!/usr/bin/env bash\n'
    printf 'hook_probe() {\n'
    printf '  python3 - %s\n' "<<'PY'"
    printf '%s\nPY\n}\n' "${3:-print(\"ok\")}"
  } > "${d}/linux/host-config/git-hooks/pre-commit"
  { printf 'emit_head() {\n'
    printf '  cat %s\n' "<<'TPL_PY_HEAD'"
    printf 'location / {\nTPL_PY_HEAD\n}\n'
    printf 'emit_tail() {\n'
    printf '  cat %s\n' "<<'TPL_PY_TAIL'"
    printf '  proxy_pass http://app;\n}\nTPL_PY_TAIL\n}\n'
  } > "${d}/linux/scripts/tpl.sh"
  _run "${d}"
}

t_case "the pin the fixture carries is the one tool-pins.env holds"
t_assert_ok test -n "${PIN}"

t_case "reading the pin makes no noise: tool-pins.env is data, and is never sourced"
# `source tool-pins.env` would run 86, 89 and 90 from CUDA_ARCHITECTURES as commands.
_d="$(_mkroot)"
printf 'CUDA_ARCHITECTURES=80;86;89;90\nRUFF_VERSION=%s\n' "${PIN}" \
  > "${_d}/linux/scripts/01-core/tool-pins.env"
printf 'print("ok")\n' > "${_d}/docs/scripts/subject.py"
t_assert_eq "" "$(bash "${_d}/linux/scripts/lint-python.sh" 2>&1 >/dev/null)" \
  "a gate that runs in every hook must not print shell errors from its own pin lookup"
t_assert_contains "$(_run "${_d}")" "rc=0" "and the value must still load, not break the gate"

t_case "an undefined name fails the gate tier"
_out="$(_lint 'print(nope)')"
t_assert_contains "${_out}" "python gate pass failed" "F82 is the whole point of the gate tier"
t_assert_contains "${_out}" "rc=1" "printing findings is not enough; it must exit non-zero"

t_case "a syntax error fails the gate tier"
_out="$(_lint 'def f(:')"
t_assert_contains "${_out}" "rc=1" "an E9 syntax error is a real crash waiting to happen"

t_case "a return in finally cannot silence an exception"
_out="$(_lint $'def broken():\n    try:\n        raise RuntimeError("lost")\n    finally:\n        return 1')"
t_assert_contains "${_out}" "B012" "the stricter tier must inspect exception cleanup"
t_assert_contains "${_out}" "rc=1"

t_case "a loop closure must bind the value it captures"
_out="$(_lint $'callbacks = []\nfor value in range(2):\n    callbacks.append(lambda: value)')"
t_assert_contains "${_out}" "B023" "late binding silently makes every callback use the last value"
t_assert_contains "${_out}" "rc=1"

t_case "safe cleanup and explicitly bound loop closures pass"
_out="$(_lint $'def safe():\n    try:\n        return 1\n    finally:\n        print("cleanup")\ncallbacks = []\nfor value in range(2):\n    callbacks.append(lambda value=value: value)')"
t_assert_contains "${_out}" "gate pass (E9,F63,F7,F82,B012,B023): clean"
t_assert_contains "${_out}" "rc=0"

t_case "a clean file passes both tiers"
_out="$(_lint 'print("ok")')"
t_assert_contains "${_out}" "gate pass (E9,F63,F7,F82,B012,B023): clean"
t_assert_contains "${_out}" "advisory pass: clean"
t_assert_contains "${_out}" "rc=0" "nothing to report, nothing to fail"

t_case "a tree with no embedded Python still passes after a complete extraction"
_d="$(_mkroot)"
printf 'print("ok")\n' > "${_d}/docs/scripts/subject.py"
printf 'echo hello\n' > "${_d}/linux/scripts/plain.sh"
_out="$(_run "${_d}")"
t_assert_contains "${_out}" "gate pass (E9,F63,F7,F82,B012,B023): clean"
t_assert_contains "${_out}" "rc=0"

t_case "a missing extractor makes the gate fail before Ruff"
_d="$(_mkroot)"
printf 'print("ok")\n' > "${_d}/docs/scripts/subject.py"
rm -f "${_d}/linux/scripts/extract_embedded_python.py"
_out="$(_run "${_d}")"
t_assert_contains "${_out}" "Embedded Python extraction failed"
t_assert_contains "${_out}" "rc=1"

t_case "large shell scopes reach Ruff through multiple bounded extractor calls"
_batch_d="$(_mkroot)"
printf 'print("ok")\n' > "${_batch_d}/docs/scripts/subject.py"
for _batch_n in $(seq -w 1 33); do
  _batch_file="${_batch_d}/linux/scripts/batch-${_batch_n}.sh"
  if [ "${_batch_n}" = 01 ] || [ "${_batch_n}" = 33 ]; then
    { printf 'python3 - %s\n' "<<'PY'"
      printf 'print(nope_batch_%s)\nPY\n' "${_batch_n}"
    } > "${_batch_file}"
  else
    printf 'echo ok\n' > "${_batch_file}"
  fi
done
_batch_py="${_batch_d}/python-wrapper"
cat > "${_batch_py}" <<'BATCH_SH'
#!/usr/bin/env bash
if [ "$1" = linux/scripts/extract_embedded_python.py ]; then
  printf '%s\n' "$#" >> "${EXTRACT_BATCH_LOG}"
  [ "${FAIL_EXTRACT_BATCH:-0}" -ne "$(wc -l < "${EXTRACT_BATCH_LOG}")" ] || exit 42
fi
exec python3 "$@"
BATCH_SH
chmod +x "${_batch_py}"
_batch_log="$(mktemp)"
_batch_out="$(PREFLIGHT_PYTHON="${_batch_py}" EXTRACT_BATCH_LOG="${_batch_log}" bash "${_batch_d}/linux/scripts/lint-python.sh" 2>&1)"
t_assert_eq "2" "$(wc -l < "${_batch_log}")" "one child with every tracked script exceeds Git Bash's argument limit"
t_assert_eq "34" "$(sort -nr "${_batch_log}" | head -1)" "each child gets at most 32 shell paths plus two fixed arguments"
t_assert_contains "${_batch_out}" "nope_batch_01" "the first batch must reach Ruff"
t_assert_contains "${_batch_out}" "nope_batch_33" "the last batch must reach Ruff"

_batch_failure() {
  : > "${_batch_log}"
  _batch_out="$(PREFLIGHT_PYTHON="${_batch_py}" EXTRACT_BATCH_LOG="${_batch_log}" FAIL_EXTRACT_BATCH="$1" \
    bash "${_batch_d}/linux/scripts/lint-python.sh" 2>&1)"; _batch_rc=$?
  t_assert_contains "${_batch_out}" "Embedded Python extraction failed"
  t_assert_eq "$1" "$(wc -l < "${_batch_log}")"
  t_assert_eq "1" "${_batch_rc}"
}

t_case "a later extractor batch failure makes the whole lint verdict fail"
_batch_failure 2
t_case "a full extractor batch failure stops before later batches run"
_batch_failure 1
rm -rf "${_batch_d}" "${_batch_log}"

t_case "an advisory-only finding is reported but does not fail"
_out="$(_lint 'import os')"
t_assert_contains "${_out}" "gate pass (E9,F63,F7,F82,B012,B023): clean" "F401 is outside the gate tier"
t_assert_contains "${_out}" "ADVISORY: findings above are informational"
t_assert_contains "${_out}" "rc=0" "the adoption ramp must stay advisory"

t_case "a full hub sweep rejects unused Python imports"
_out="$(_targets 'import os' 'print("ok")')"
t_assert_contains "${_out}" "F401"
t_assert_contains "${_out}" "hub unused-binding gate failed"
t_assert_contains "${_out}" "rc=1"

t_case "a full hub sweep rejects unused imports in shell heredocs"
_out="$(_targets 'print("ok")' 'import os')"
t_assert_contains "${_out}" "F401"
t_assert_contains "${_out}" "linux/scripts/probe.sh:3:"
t_assert_contains "${_out}" "rc=1"

t_case "a full hub sweep rejects unused assignments"
_out="$(_targets $'def answer():\n    unused = 42\n    return 1' 'print("ok")')"
t_assert_contains "${_out}" "F841"
t_assert_contains "${_out}" "rc=1"

t_case "a full hub sweep rejects unused unpacked variables"
_out="$(_targets $'def answer():\n    first, second = (1, 2)\n    return first\nprint(answer())' 'print("ok")')"
t_assert_contains "${_out}" "RUF059"
t_assert_contains "${_out}" "rc=1"

t_case "a full hub sweep rejects abbreviated regex flags in Python"
_out="$(_targets $'import re\nprint(re.search("a", "a", re.M))' 'print("ok")')"
t_assert_contains "${_out}" "FURB167"
t_assert_contains "${_out}" "hub regex-flag gate failed"
t_assert_contains "${_out}" "rc=1"

t_case "a full hub sweep rejects abbreviated regex flags in shell heredocs"
_out="$(_targets 'print("ok")' $'import re\nprint(re.search("a", "a", re.M))')"
t_assert_contains "${_out}" "FURB167"
t_assert_contains "${_out}" "linux/scripts/probe.sh:"
t_assert_contains "${_out}" "rc=1"

t_case "explicit targets keep regex aliases advisory during consumer adoption"
_out="$(_lint $'import re\nprint(re.search("a", "a", re.M))')"
t_assert_contains "${_out}" "FURB167"
t_assert_contains "${_out}" "ADVISORY: findings above are informational"
t_assert_contains "${_out}" "rc=0"

t_case "long regex flag names pass the hub gate"
_out="$(_targets $'import re\nprint(re.search("a", "a", re.MULTILINE))' 'print("ok")')"
t_assert_contains "${_out}" "hub regex-flag gate (FURB167): clean"
t_assert_contains "${_out}" "rc=0"

t_case "a clean tree of every target shape passes"
_out="$(_targets 'print("ok")' 'print("ok")')"
t_assert_contains "${_out}" "gate pass (E9,F63,F7,F82,B012,B023): clean" \
  "the nginx TPL_PY_* family must not be linted as Python"
t_assert_contains "${_out}" "rc=0"

t_case "a gate-tier error in a plain .py still fails with heredocs in the tree"
_out="$(_targets 'print(nope_in_py)' 'print("ok")')"
t_assert_contains "${_out}" "nope_in_py" "the plain-.py target must survive the extraction step"
t_assert_contains "${_out}" "rc=1"

t_case "a gate-tier error inside a shell heredoc fails the gate"
_out="$(_targets 'print("ok")' 'print(nope_in_heredoc)')"
t_assert_contains "${_out}" "nope_in_heredoc" \
  "switching extraction off leaves ~775 heredoc lines outside the gate, silently"
t_assert_contains "${_out}" "python gate pass failed"
t_assert_contains "${_out}" "rc=1"

t_case "a late-bound closure inside a shell heredoc fails the gate"
_out="$(_targets 'print("ok")' $'callbacks = []\nfor value in range(2):\n    callbacks.append(lambda: value)')"
t_assert_contains "${_out}" "B023" "new correctness rules must cover extracted shell Python too"
t_assert_contains "${_out}" "rc=1"

t_case "the heredoc finding names the shell file and the line the reader must open"
t_needs "a POSIX python3 (Windows' python sees drive-letter paths)" t_posix_python
_out="$(_targets 'print("ok")' 'print(nope_in_heredoc)')"
t_assert_contains "${_out}" "linux/scripts/probe.sh:3:" \
  "probe__2.py:1: is two numbers the reader has to add up by hand: opener line 2 plus body line 1"
t_assert_eq 0 "$(printf '%s' "${_out}" | grep -c 'probe__2\.py')" \
  "and the throwaway name must be gone, not printed alongside"

t_case "a gate-tier error inside a git-hook heredoc fails the gate"
_out="$(_targets 'print("ok")' 'print("ok")' 'print(nope_in_hook)')"
t_assert_contains "${_out}" "nope_in_hook" \
  "a hook carries no .sh suffix: dropping the git-hooks half of the file list leaves the pre-commit hook's embedded Python outside the gate, silently"
t_assert_contains "${_out}" "python gate pass failed"
t_assert_contains "${_out}" "rc=1"

t_case "the git-hook finding names the hook file and the line the reader must open"
t_needs "a POSIX python3 (Windows' python sees drive-letter paths)" t_posix_python
_out="$(_targets 'print("ok")' 'print("ok")' 'print(nope_in_hook)')"
t_assert_contains "${_out}" "linux/host-config/git-hooks/pre-commit:4:" \
  "a hook has no .sh suffix and no line of its own in the extracted name -- opener 3 plus body 1"

t_case "the gate is registered in preflight"
t_assert_contains "$(cat "${S}/preflight.sh")" "python-lint" "an unwired gate is not a gate"

# The consumer root (--root): the SHIPPED gate over a throwaway consumer, the invocation a submodule checkout needs.
# shellcheck source=linux/scripts/tests/lint-consumer-fixture.sh
source "${TESTS_DIR}/lint-consumer-fixture.sh"
# Heredoc openers are printf ARGUMENTS so this suite is not itself a target.
_plant() {  # <dir> <shape>
  case "$2" in
    broken)   printf 'print(nope_in_consumer)\n' > "$1/app.py" ;;
    vendored) printf 'print(nope_in_vendored)\n' > "$1/vendored.py" ;;
    clean)    printf 'print("ok")\n' > "$1/app.py" ;;
    heredoc)  printf 'print("ok")\n' > "$1/app.py"
              { printf 'probe() {\n'
                printf '  python3 - %s\n' "<<'PY'"
                printf 'print(nope_in_consumer_heredoc)\nPY\n}\n'
              } > "$1/probe.sh" ;;
  esac
}
# _consumer <clean|broken|empty|heredoc> [vendored] -> a consumer checkout.

_at_root() { bash "${S}/lint-python.sh" --root "$1" 2>&1; }

t_case "--root decides WHICH tree is graded, and the verdicts follow the argument"
_c_clean="$(_consumer clean)"
_c_broken="$(_consumer broken)"
t_assert_eq "0" "$(t_rc bash "${S}/lint-python.sh" --root "${_c_clean}")" \
  "the gate must be able to be green over a consumer, or the red below proves only that it is broken"
t_assert_eq "1" "$(t_rc bash "${S}/lint-python.sh" --root "${_c_broken}")" \
  "a gate that ignored --root would grade ANTfrastructure -- which is clean -- and report OK"
t_assert_contains "$(_at_root "${_c_broken}")" "nope_in_consumer" \
  "the finding has to name the consumer's undefined name to be actionable"

t_case "the banner names the tree that was graded, and how much of it"
_out="$(_at_root "${_c_clean}")"
t_assert_contains "${_out}" "python lint under ${_c_clean}"
t_assert_contains "${_out}" ": 1 file(s)" \
  "a count that included this repo's own Python would be a verdict about the wrong tree"

t_case "a vendored checkout inside the consumer is a gitlink, and is not graded"
_c_vendored="$(_consumer clean vendored)"
t_assert_ok test -f "${_c_vendored}/${T_VENDORED}/vendored.py"
t_assert_eq "0" "$(t_rc bash "${S}/lint-python.sh" --root "${_c_vendored}")" \
  "grading the vendored hub AS the consumer is the same wrong-tree bug from the other direction"
t_assert_eq "1" "$(t_rc bash "${S}/lint-python.sh" \
  "${_c_vendored}/${T_VENDORED}/vendored.py")" \
  "and the vendored file really is broken, so the green above is about scope, not a clean file"

t_case "heredoc Python in the CONSUMER's shell reaches ruff too"
# Heredoc Python in a consumer must reach ruff too; skipping extraction under --root would be a half-gate.
_c_heredoc="$(_consumer heredoc)"
t_assert_contains "$(_at_root "${_c_heredoc}")" "nope_in_consumer_heredoc"
t_assert_eq "1" "$(t_rc bash "${S}/lint-python.sh" --root "${_c_heredoc}")"

t_case "an explicit shell file reaches the embedded Python check alongside a Python file"
_out="$(bash "${S}/lint-python.sh" "${_c_heredoc}/app.py" "${_c_heredoc}/probe.sh" 2>&1)"
t_assert_contains "${_out}" "nope_in_consumer_heredoc"
t_assert_eq "1" "$(t_rc bash "${S}/lint-python.sh" "${_c_heredoc}/app.py" "${_c_heredoc}/probe.sh")"

t_case "an explicit shell-only list with embedded Python still fails on its bug"
_out="$(bash "${S}/lint-python.sh" "${_c_heredoc}/probe.sh" 2>&1)"
t_assert_contains "${_out}" "nope_in_consumer_heredoc"
t_assert_eq "1" "$(t_rc bash "${S}/lint-python.sh" "${_c_heredoc}/probe.sh")"

t_case "a shell-only explicit list with no embedded blocks is an honest empty Python scope"
printf 'echo hello\n' > "${_c_heredoc}/plain.sh"
_out="$(bash "${S}/lint-python.sh" "${_c_heredoc}/plain.sh" 2>&1)"
t_assert_contains "${_out}" "No Python source or embedded blocks"
t_assert_eq "0" "$(t_rc bash "${S}/lint-python.sh" "${_c_heredoc}/plain.sh")"

t_case "a missing explicit shell file fails the gate rather than losing its extraction scope"
_out="$(bash "${S}/lint-python.sh" "${_c_clean}/app.py" "${_c_clean}/gone.sh" 2>&1)"
t_assert_contains "${_out}" "cannot read"
t_assert_contains "${_out}" "Embedded Python extraction failed"
t_assert_eq "1" "$(t_rc bash "${S}/lint-python.sh" "${_c_clean}/app.py" "${_c_clean}/gone.sh")"

t_case "an empty file list under an explicit root is an ERROR, never a green pass"
_c_empty="$(_consumer empty)"
t_assert_eq "1" "$(t_rc bash "${S}/lint-python.sh" --root "${_c_empty}")"
t_assert_contains "$(_at_root "${_c_empty}")" "No Python files found to lint under ${_c_empty}"

t_case "a root that is not a git checkout refuses instead of guessing a scope"
_c_nogit="$(mktemp -d "${_work}/nogit.XXXXXX")"
printf 'print("ok")\n' > "${_c_nogit}/app.py"
t_assert_eq "1" "$(t_rc bash "${S}/lint-python.sh" --root "${_c_nogit}")"
t_assert_contains "$(_at_root "${_c_nogit}")" "is not a git checkout" \
  "guessing a scope out of a non-checkout is a scope nobody chose"

t_case "a root that does not exist refuses, it does not fall back to this repo"
t_assert_eq "1" "$(t_rc bash "${S}/lint-python.sh" --root "${_work}/no-such-checkout")" \
  "falling back would grade a clean tree and report OK for a checkout nobody looked at"

t_case "--root with no value is a usage error, not a silent default"
t_assert_eq "1" "$(t_rc bash "${S}/lint-python.sh" --root)"

t_summary
