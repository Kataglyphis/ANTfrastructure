#!/usr/bin/env bash
# Tests for extract-embedded-python.py — the bridge that lets ruff see Python
# living in shell heredocs (775 lines were invisible before 2026-09-01).
# The two behaviours below were each proven by mutation. docs/code-quality-tooling.md
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
EXTRACT="${TESTS_DIR}/../extract-embedded-python.py"
PY="${PREFLIGHT_PYTHON:-python3}"

_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT

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
"${PY}" "${EXTRACT}" "${_work}/out" "${_work}/direct.sh" >/dev/null 2>&1
t_assert_eq "1" "$(find "${_work}/out" -name 'direct__*.py' | wc -l)"
t_assert_contains "$(cat "${_work}/out"/direct__*.py 2>/dev/null)" "import sys"

t_case "an opener with trailing redirections is still extracted"
rm -rf "${_work}/out"
"${PY}" "${EXTRACT}" "${_work}/out" "${_work}/redirected.sh" >/dev/null 2>&1
t_assert_eq "1" "$(find "${_work}/out" -name 'redirected__*.py' | wc -l)" \
  "the first extractor missed exactly this shape"

t_case "a cat'ed fragment is NOT extracted"
rm -rf "${_work}/out"
"${PY}" "${EXTRACT}" "${_work}/out" "${_work}/fragment.sh" >/dev/null 2>&1
t_assert_eq "0" "$(find "${_work}/out" -name '*.py' 2>/dev/null | wc -l)" \
  "linting a fragment alone reports bogus undefined names"

t_case "the real tree yields extractable blocks, and the lint gate consumes them"
rm -rf "${_work}/out"
"${PY}" "${EXTRACT}" "${_work}/out" $(find "${TESTS_DIR}/.." -name '*.sh' -type f) >/dev/null 2>&1
_n="$(find "${_work}/out" -name '*.py' | wc -l)"
t_assert_ok test "${_n}" -ge 5
t_assert_contains "$(cat "${TESTS_DIR}/../lint-python.sh")" "extract-embedded-python.py" \
  "an extractor nothing calls is not a gate"

t_summary
