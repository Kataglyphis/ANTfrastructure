#!/usr/bin/env bash
# Tests for extract_embedded_python.py — the bridge that lets ruff see Python
# living in shell heredocs (775 lines were invisible before 2026-09-01).
# The two behaviours below were each proven by mutation. docs/code-quality-tooling.md
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
EXTRACT="${TESTS_DIR}/../extract_embedded_python.py"
PY="${PREFLIGHT_PYTHON:-python3}"

_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT

# One extractor run against a fresh out dir — the shape every case repeats.
_extract_fresh() {
  rm -rf "${_work}/out"
  "${PY}" "${EXTRACT}" "${_work}/out" "$@" >/dev/null 2>&1
}

cat > "${_work}/direct.sh" <<'SH'
run_probe() {
  python3 - <<'PY'
import sys
print(sys.version)
PY
}
SH

# A trailing redirection on the opener line is why the first version of the
# extractor silently skipped smoke-runtime-image.sh's probe.
cat > "${_work}/redirected.sh" <<'SH'
"$py" - <<'PY' 2>/dev/null || echo 'probe crashed'
import os
print(os.name)
PY
SH

# `cat`ed blocks are FRAGMENTS assembled into one program later; alone they are
# not valid Python and would produce false undefined-name failures.
cat > "${_work}/fragment.sh" <<'SH'
_tail() {
  cat <<'PY_TAIL'
for line in proven:
    print(line)
PY_TAIL
}
SH

t_case "a directly-executed heredoc is extracted"
_extract_fresh "${_work}/direct.sh"
t_assert_eq "1" "$(find "${_work}/out" -name 'direct__*.py' | wc -l)"
t_assert_contains "$(cat "${_work}/out"/direct__*.py 2>/dev/null)" "import sys"

t_case "an opener with trailing redirections is still extracted"
_extract_fresh "${_work}/redirected.sh"
t_assert_eq "1" "$(find "${_work}/out" -name 'redirected__*.py' | wc -l)" \
  "the first extractor missed exactly this shape"

t_case "a cat'ed fragment is NOT extracted"
_extract_fresh "${_work}/fragment.sh"
t_assert_eq "0" "$(find "${_work}/out" -name '*.py' 2>/dev/null | wc -l)" \
  "linting a fragment alone reports bogus undefined names"

t_case "the real tree yields extractable blocks, and the lint gate consumes them"
_extract_fresh $(find "${TESTS_DIR}/.." -name '*.sh' -type f)
_n="$(find "${_work}/out" -name '*.py' | wc -l)"
t_assert_ok test "${_n}" -ge 5
t_assert_contains "$(cat "${TESTS_DIR}/../lint-python.sh")" "extract_embedded_python.py" \
  "an extractor nothing calls is not a gate"

# A FAMILY of cat'ed fragments (two or more sharing a marker prefix) IS
# assembled and extracted -- that is how the 217 lines of genai smoke Python
# finally reach ruff. A lone fragment still is not, per the case above.
# One extract-and-count helper: the two cases below used to repeat these four
# lines verbatim, which the code-dupes gate rightly flagged.
# _count_extracted <outdir> <script.sh> <name-glob>
_count_extracted() {
  python3 "${EXTRACT}" "$1" "$2" >/dev/null 2>&1
  find "$1" -name "$3" 2>/dev/null | wc -l
}

t_case "a multi-fragment family is assembled and extracted"
_FAM="${_work}/fam.sh"
cat > "${_FAM}" <<'FAMSH'
emit_a() {
  cat <<'DEMO_PY_A'
def add(a, b):
    return a + b
DEMO_PY_A
}
emit_b() {
  cat <<'DEMO_PY_B'
print(add(1, 2))
DEMO_PY_B
}
FAMSH
_FOUT="${_work}/famout"
t_assert_eq "1" "$(_count_extracted "${_FOUT}" "${_FAM}" '*demo_py*.py')" \
  "the two DEMO_PY_* fragments must assemble into one file"
t_assert_contains "$(cat "${_FOUT}"/*demo_py*.py 2>/dev/null)" "def add" "fragment A missing"
t_assert_contains "$(cat "${_FOUT}"/*demo_py*.py 2>/dev/null)" "print(add" "fragment B missing"

t_case "markers containing DIGITS are not silently skipped"
# GENAI_PY_T1..T4 were missed for exactly this reason: the marker class excluded
# digits, so four of six fragments never reached ruff and nobody could tell.
_DIG="${_work}/dig.sh"
cat > "${_DIG}" <<'DIGSH'
one() {
  cat <<'NUM_PY_1'
x = 1
NUM_PY_1
}
two() {
  cat <<'NUM_PY_2'
print(x)
NUM_PY_2
}
DIGSH
_DOUT="${_work}/digout"
t_assert_eq "1" "$(_count_extracted "${_DOUT}" "${_DIG}" '*num_py*.py')" \
  "digit-suffixed markers must be seen"

t_case "an UPPERCASE interpreter variable is recognised"
# `"${PY}" - <<'PYEOF'` did not match the old lowercase-only pattern, so the
# ~330-line program inside assert_pinned_versions -- the largest embedded Python
# in the tree -- was never linted, and nothing said so.
_UP="${_work}/upper.sh"
cat > "${_UP}" <<'UPSH'
run_it() {
  PY=python3
  "${PY}" - <<'PYEOF'
value = 41 + 1
print(value)
PYEOF
}
UPSH
_UOUT="${_work}/upperout"
t_assert_eq "1" "$(_count_extracted "${_UOUT}" "${_UP}" '*.py')" \
  "\${PY} must be recognised as an interpreter"
t_assert_contains "$(cat "${_UOUT}"/*.py 2>/dev/null)" "value = 41" "body missing"

t_case "a commented-out RUN opener extracts nothing"
# CI-red on 2026-09-02: prose describing the pattern was read as a real heredoc,
# so shell lines reached ruff as Python. Both fixtures below DO satisfy BLOCK
# (opener + closing marker), so they extract without the guard -- that is what
# makes these tests able to fail. docs/code-quality-tooling.md
_CMT="${_work}/comment.sh"
cat > "${_CMT}" <<'CMTSH'
# described, not used: python3 - <<'PYEOF'
this is not python ]]]
PYEOF
CMTSH
_COUT="${_work}/commentout"
t_assert_eq "0" "$(_count_extracted "${_COUT}" "${_CMT}" '*.py')" \
  "a commented RUN opener must extract nothing"

t_case "commented-out cat openers do not assemble a family"
_CMT2="${_work}/comment2.sh"
cat > "${_CMT2}" <<'CMT2SH'
    # quoted in prose: cat <<'DEMO_PY'
x = 1
DEMO_PY
    # and again, same family: cat <<'DEMO_PY'
y = 2
DEMO_PY
CMT2SH
_C2OUT="${_work}/comment2out"
t_assert_eq "0" "$(_count_extracted "${_C2OUT}" "${_CMT2}" '*.py')" \
  "two commented cat openers must not assemble (indented # included)"

t_summary
