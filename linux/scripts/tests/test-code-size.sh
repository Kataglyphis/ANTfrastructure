#!/usr/bin/env bash
# Tests for verify_code_size.py. The gate derives its root from its own path, so
# each case builds a throwaway tree and runs the real script against it. Both
# metrics share one four-way contract, so the cases below share one fixture
# builder and one runner.
# docs/code-quality-tooling.md#code-size--functions-and-files-code-size
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SCRIPTS_DIR="$(cd "${TESTS_DIR}/.." && pwd)"
PY="${PREFLIGHT_PYTHON:-python3}"

# An empty tree with the gate and its one import installed.
_tree() {
  local d
  d="$(mktemp -d)"
  mkdir -p "${d}/linux/scripts"
  cp "${SCRIPTS_DIR}/verify_code_size.py" "${SCRIPTS_DIR}/quality_allow.py" "${d}/linux/scripts/"
  printf '%s' "${d}"
}

# A tree holding one subject.sh. `shape` decides whether the <n> lines form one
# long FUNCTION or just a long FILE, and which allow file the line lands in.
_fixture() {
  local shape="$1" n="$2" allow="${3-}" d
  d="$(_tree)"
  # NOTE: the redirect must sit inside each arm. A trailing `esac > "${subject}"`
  # expands ${subject} before any arm runs, so the content lands in the default file.
  case "${shape}" in
    function)
      { echo "big() {"; for _ in $(seq 1 $((n - 2))); do echo "  :"; done; echo "}"; } \
        > "${d}/linux/scripts/subject.sh"
      [ -n "${allow}" ] && printf '%s\n' "${allow}" > "${d}/linux/scripts/function-size.allow"
      ;;
    twice)
      # The same name defined twice, LONG first and short after. "Last wins" would
      # then report 3 lines and the offender would hide behind its own redefinition,
      # so the gate must take the longest.
      { echo "big() {"; for _ in $(seq 1 $((n - 2))); do echo "  :"; done; echo "}"
        echo "big() {"; echo "  :"; echo "}"; } \
        > "${d}/linux/scripts/subject.sh"
      [ -n "${allow}" ] && printf '%s\n' "${allow}" > "${d}/linux/scripts/function-size.allow"
      ;;
    pyfunc)
      { echo "def big():"; for _ in $(seq 1 $((n - 1))); do echo "    pass"; done; } \
        > "${d}/linux/scripts/subject.py"
      [ -n "${allow}" ] && printf '%s\n' "${allow}" > "${d}/linux/scripts/function-size.allow"
      ;;
    dockerfile)
      for _ in $(seq 1 "${n}"); do echo "# ."; done > "${d}/linux/Dockerfile.subject"
      [ -n "${allow}" ] && printf '%s\n' "${allow}" > "${d}/linux/scripts/file-size.allow"
      ;;
    *)
      for _ in $(seq 1 "${n}"); do echo ":"; done > "${d}/linux/scripts/subject.sh"
      [ -n "${allow}" ] && printf '%s\n' "${allow}" > "${d}/linux/scripts/file-size.allow"
      ;;
  esac
  printf '%s' "${d}"
}

_run() { t_out "${PY}" "$1/linux/scripts/verify_code_size.py"; }
_rc()  { t_rc "${PY}" "$1/linux/scripts/verify_code_size.py"; }

_says() {
  local shape="$1" n="$2" allow="$3" want="$4" why="$5" fix out
  fix="$(_fixture "${shape}" "${n}" "${allow}")"
  out="$(_run "${fix}")"
  rm -rf "${fix}"
  t_assert_contains "${out}" "${want}" "${why}"
}

_exits() {
  local shape="$1" n="$2" allow="$3" want="$4" why="$5" fix got
  fix="$(_fixture "${shape}" "${n}" "${allow}")"
  got="$(_rc "${fix}")"
  rm -rf "${fix}"
  t_assert_eq "${want}" "${got}" "${why}"
}

# ── under the limit ──────────────────────────────────────────────────────────
t_case "sizes under the limit are not reported"
_exits function 10 "" 0 "10 lines is under the function limit"
_exits file      50 "" 0 "50 lines is under the file limit"

# ── the four-way contract, both metrics ──────────────────────────────────────
t_case "a new offender fails, and actually exits non-zero"
_says  function 100 "" "not frozen" "an unfrozen function must name the allow file"
_exits function 100 "" 1 "printing FAIL is not enough; it must fail"
_says  file     900 "" "not frozen" "an unfrozen file must name the allow file"
_exits file     900 "" 1 "the file half must fail the gate too, not just print"

t_case "a frozen entry at its recorded length passes"
_exits function 100 "linux/scripts/subject.sh | big | 100 | baseline" 0 "the baseline is the contract"
_exits file     900 "linux/scripts/subject.sh | 900 | baseline"       0 "same for files"

t_case "growth past the frozen number fails"
_says function 100 "linux/scripts/subject.sh | big | 90 | baseline" \
  "GREW from 90 to 100" "frozen numbers may only go down"
_says file 900 "linux/scripts/subject.sh | 850 | baseline" \
  "GREW from 850 to 900" "same for files"

t_case "shrinking without updating the entry fails, so the baseline cannot rot"
_says function 100 "linux/scripts/subject.sh | big | 110 | baseline" \
  "shrank from 110 to 100" "an improvement must be recorded"
_says file 900 "linux/scripts/subject.sh | 950 | baseline" \
  "shrank from 950 to 900" "same for files"

t_case "a reason may carry a |, because each allow file declares its key arity"
_exits function 100 "linux/scripts/subject.sh | big | 100 | baseline | 90 | see the table" 0 \
  "two key columns are declared, so a | in the reason cannot shift the count"
_exits file 900 "linux/scripts/subject.sh | 900 | baseline | 850 | see the table" 0 \
  "one key column for files, same rule"

t_case "a freeze for something no longer over the limit is stale"
_says function 10 "linux/scripts/subject.sh | big | 100 | baseline" \
  "STALE freeze" "delete the line once it drops under"
_says file 50 "linux/scripts/subject.sh | 900 | baseline" \
  "STALE freeze" "same for files"

# ── the metrics added on 2026-09-03: python functions and Dockerfiles ────────
t_case "a long python function is measured, via ast rather than a regex"
_says  pyfunc 100 "" "not frozen" "def bodies count too, and end_lineno is exact"
_exits pyfunc 100 "linux/scripts/subject.py | big | 100 | baseline" 0 \
  "frozen at its real length, it passes"

t_case "a long Dockerfile is measured, even though it has no functions"
_says  dockerfile 900 "" "not frozen" "Dockerfile.media is the largest file in the tree"
_exits dockerfile 900 "linux/Dockerfile.subject | 900 | baseline" 0 "frozen, it passes"

t_case "a name defined twice is measured at its longest, not its last"
_says  twice 100 "" "is 100 lines" "the short redefinition must not mask the long one"
_exits twice 100 "linux/scripts/subject.sh | big | 100 | baseline" 0 "frozen at the real length"

# ── extents: braces that are not code ────────────────────────────────────────
# subject.sh is read from stdin and every function reports its own length, so a
# case asserts the measured extent directly. docs/code-quality-tooling.md#what-a-shell-functions-extent-is
_measure() {
  local d out
  d="$(_tree)"
  cat > "${d}/linux/scripts/subject.sh"
  out="$(t_out env FUNCTION_SIZE_LIMIT=0 "${PY}" "${d}/linux/scripts/verify_code_size.py")"
  rm -rf "${d}"
  printf '%s' "${out}"
}

_no_function() {
  t_assert_eq "" "$(printf '%s' "$1" | grep -e ":$2 is" || true)" \
    "$2 is not a definition: $3"
}

t_case "a } inside a comment does not end the function early"
_out="$(_measure <<'SH'
big() {
  # a stray } in prose, as generate_pkgconfig_file explains its own bug
  :
}
SH
)"
t_assert_contains "${_out}" "subject.sh:big is 4 lines" "comment text is not code"

t_case "a } inside a single- or double-quoted string does not end the function early"
_out="$(_measure <<'SH'
sq() {
  echo '}'
  :
}
dq() {
  echo "}"
  :
}
SH
)"
t_assert_contains "${_out}" "subject.sh:sq is 4 lines" "'}' is a string, not a block end"
t_assert_contains "${_out}" "subject.sh:dq is 4 lines" '"}" is a string, not a block end'

t_case "a } inside a heredoc body does not end the function early"
_out="$(_measure <<'SH'
heredoc() {
  cat <<'BODY'
}
an apostrophe ' in the body must not open a string either
BODY
  :
}
SH
)"
t_assert_contains "${_out}" "subject.sh:heredoc is 7 lines" "a heredoc body is data"

t_case "a definition inside a heredoc body is fixture text, not a function"
_out="$(_measure <<'SH'
writer() {
  cat > /tmp/qw4-fixture.sh <<'FIXTURE'
phantom() {
  :
}
FIXTURE
}
SH
)"
t_assert_contains "${_out}" "subject.sh:writer is 7 lines" "the writer runs to its own brace"
_no_function "${_out}" "phantom" "it is a line of the heredoc the writer emits"

t_case "a { inside a comment no longer swallows the rest of the file"
# The old raw count never closed outer, so outer was invisible to every gate that
# inherits these extents and inner sat inside an extent that ran to EOF.
_out="$(_measure <<'SH'
outer() {
  # an unbalanced { in prose
  :
}
inner() {
  :
}
SH
)"
t_assert_contains "${_out}" "subject.sh:outer is 4 lines" "outer must be measured at all"
t_assert_contains "${_out}" "subject.sh:inner is 3 lines" "inner is its own function"

t_summary
