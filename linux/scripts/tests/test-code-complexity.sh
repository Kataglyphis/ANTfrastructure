#!/usr/bin/env bash
# Tests for verify_code_complexity.py. The gate derives its root from its own path,
# so each case copies it with its two imports into a throwaway tree and feeds a
# subject.sh on stdin. Measured numbers are read back through the real CLI with the
# limits forced to zero, so no case depends on the parser's internals.
# docs/code-quality-tooling.md#shell-complexity-code-complexity
set -u
source "$(dirname "${BASH_SOURCE[0]}")/test-harness.sh"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="${PREFLIGHT_PYTHON:-python3}"
GATE=verify_code_complexity.py
ROW="linux/scripts/subject.sh | f"

# _tree [allow-row...]: a tree holding the gate, its imports, subject.sh from stdin
# and, when rows are given, a code-complexity.allow.
_tree() {
  local root m; root="$(mktemp -d)"
  for m in "${GATE}" verify_code_size.py quality_allow.py; do
    install -D -m 0644 "${SRC}/${m}" "${root}/linux/scripts/${m}"
  done
  cat > "${root}/linux/scripts/subject.sh"
  [ $# -eq 0 ] || printf '%s\n' "$@" > "${root}/linux/scripts/code-complexity.allow"
  printf '%s' "${root}"
}
_gate() { "${PY}" "$1/linux/scripts/${GATE}" 2>&1; echo "rc=$?"; }
# _measure <tree> <function> <cc|nesting>: the number the gate itself reports
_measure() {
  COMPLEXITY_LIMIT=0 NESTING_LIMIT=-1 "${PY}" "$1/linux/scripts/${GATE}" 2>&1 \
    | sed -n "s|^FAIL: linux/scripts/subject.sh:$2:$3 is \([0-9]*\) .*|\1|p"
}
# subjects: f with <n> `||` operators (cc = n + 1), and f nested <n> ifs deep
_rep()  { local i; for ((i = 0; i < $1; i++)); do echo "$2"; done; }
_ors()  { echo "f() {"; _rep "$1" "a || b"; echo "}"; }
_deep() { echo "f() {"; _rep "$1" "if x; then"; echo ":"; _rep "$1" "fi"; echo "}"; }
# _run_on <generator> <n> [allow-row...]: gate output + rc for a generated subject
_run_on() {
  local fix; fix="$("$1" "$2" | _tree "${@:3}")"
  _gate "${fix}"; rm -rf "${fix}"
}
# _contract <generator> <over> <under> <metric> <count> <unit> <limit-unit>: the five
# directions for one metric; <over> makes an offender measuring <count>, <under> none.
_contract() {
  local gen="$1" over="$2" under="$3" metric="$4" n="$5" unit="$6" lim="$7" out
  out="$(_run_on "${gen}" "${over}")"
  t_assert_contains "${out}" "f:${metric} is ${n} ${unit}, over the ${lim} limit and not frozen"
  t_assert_contains "${out}" "rc=1" "printing FAIL is not enough; it must exit non-zero"
  t_assert_contains "$(_run_on "${gen}" "${over}" "${ROW} | ${metric} | ${n} | baseline")" \
    "rc=0" "frozen at its real number it passes"
  t_assert_contains "$(_run_on "${gen}" "${over}" "${ROW} | ${metric} | $((n - 1)) | baseline")" \
    "GREW from $((n - 1)) to ${n} ${unit}" "frozen numbers may only go down"
  t_assert_contains "$(_run_on "${gen}" "${over}" "${ROW} | ${metric} | $((n + 1)) | baseline")" \
    "shrank from $((n + 1)) to ${n} ${unit}" "an improvement must be recorded"
  out="$(_run_on "${gen}" "${under}" "${ROW} | ${metric} | ${n} | baseline")"
  t_assert_contains "${out}" "STALE freeze for linux/scripts/subject.sh:f:${metric}"
  t_assert_contains "${out}" "rc=1" "a stale row is a failure, not a warning"
}

# _pins <cc> <nesting> <why-cc> [why-nesting]: both metrics of the subject.sh on
# stdin, in ONE gate run. <why-nesting> defaults to <why-cc>.
_pins() {
  local fix out; fix="$(_tree)"
  out="$(COMPLEXITY_LIMIT=0 NESTING_LIMIT=-1 "${PY}" "${fix}/linux/scripts/${GATE}" 2>&1)"
  rm -rf "${fix}"
  t_assert_contains "${out}" "subject.sh:f:cc is $1 paths" "$3"
  t_assert_contains "${out}" "subject.sh:f:nesting is $2 levels" "${4:-$3}"
}

# ── the metrics on hand-built subjects ───────────────────────────────────────
t_case "a straight-line function is cc 1, nesting 0"
_pins 1 0 "\$(...) is not a decision point" "the body itself is depth 0" <<'EOF'
f() {
  x="$(cmd)"
  echo "${x}"
}
EOF

t_case "if/elif/for/while/until and && / || each add one path"
fix="$(_tree <<'EOF'
f() {
  if a; then :; elif b; then :; fi
  for x in 1; do :; done
  while c; do :; done
  until d; do :; done
  e && g || h
}
EOF
)"
t_assert_eq "8" "$(_measure "${fix}" f cc)" "1 + if elif for while until && ||"
rm -rf "${fix}"

t_case "case arms count, one per arm, and the ')' of \$(...) never does"
fix="$(_tree <<'EOF'
f() {
  case "$(uname -m)" in
    x86_64|amd64) echo "$(true)" ;;
    aarch64)
      v="$(cmd | sed 's/x/y/')"
      ;;
    *) : ;;
  esac
}
EOF
)"
t_assert_eq "4" "$(_measure "${fix}" f cc)" "three arms, two substitutions"
rm -rf "${fix}"

t_case "heredoc bodies are skipped, in every spelling"
_pins 2 1 "only the one real if is a path" "nothing inside the heredocs nests" <<'EOF'
f() {
  if out="$(python3 - <<'PYEOF'
a = b = c = 1
if a and b or c:
    for x in [a]:
        while x:
            x = 0
PYEOF
)"; then :; fi
  cat <<EOF2 > /dev/null
if if if && || for while until case
EOF2
  cat <<"EOF3"
if || && for
EOF3
  cat <<-EOF4
	if || && for
	EOF4
}
EOF

t_case "a here-string is not a heredoc: the rest of the function still counts"
fix="$(_tree <<'EOF'
f() {
  read -r a <<< "x"
  b || c
}
EOF
)"
t_assert_eq "2" "$(_measure "${fix}" f cc)" "<<< must not swallow the next lines"
rm -rf "${fix}"

t_case "operators inside quotes do not count, multi-line single quotes included"
_pins 2 0 "only the && inside \$(...) is code" "the awk braces are text" <<'EOF'
f() {
  echo 'a || b && if for while' "x && y || if" "${v:-'if'}"
  awk '
    { if (a && b) { for (i = 0; i < n; i++) { while (c) { print } } } }
  ' "$1"
  echo "$(true && false)"
}
EOF

t_case "operators in comments do not count, but \${#x} and \$# are not comments"
fix="$(_tree <<'EOF'
f() {
  # a || b && if
  echo "${#x}" $# # trailing: if a && b || c
  d || e
}
EOF
)"
t_assert_eq "2" "$(_measure "${fix}" f cc)" "one real ||"
rm -rf "${fix}"

t_case "nesting is the deepest if/for/while/case/{ } block relative to the body"
fix="$(_tree <<'EOF'
f() {
  if a; then
    for x in y; do
      while b; do
        case "${x}" in
          *) { : ; } ;;
        esac
      done
    done
  fi
}
EOF
)"
t_assert_eq "5" "$(_measure "${fix}" f nesting)" "if for while case { }"
rm -rf "${fix}"

t_case "a name defined twice is measured at its worst, not its last"
fix="$(_tree <<'EOF'
f() {
  a || b || c
}
f() {
  :
}
EOF
)"
t_assert_eq "3" "$(_measure "${fix}" f cc)" "the simple redefinition must not mask the knot"
rm -rf "${fix}"

t_case "python functions are measured via ast; an elif chain does not nest"
fix="$(_tree <<'EOF'
:
EOF
)"
cat > "${fix}/linux/scripts/subject.py" <<'EOF'
def g(a, b):
    if a:
        pass
    elif b:
        pass
    elif a and b:
        pass
    elif a or b:
        pass
    else:
        pass
    return [x for x in a if x if b]
EOF
out="$(COMPLEXITY_LIMIT=0 NESTING_LIMIT=-1 "${PY}" "${fix}/linux/scripts/${GATE}" 2>&1)"
t_assert_contains "${out}" "subject.py:g:cc is 9 paths" "1 + 4 ifs + 2 boolops + 2 comprehension ifs"
t_assert_contains "${out}" "subject.py:g:nesting is 1 levels" "elif continues its if's depth"
rm -rf "${fix}"

t_case "an unquoted keyword in argument position is a word, not a branch"
_pins 1 0 "a bare 'for' after a command name is text" "and it opens no block that never closes" <<'EOF'
f() {
  echo for x
  err Could not resolve host tools for cross wheel build
  note No packaging detected while scanning done esac fi
}
EOF

t_case "the same keywords in command position still count"
_pins 6 2 "for + two ifs + && + while" "the inner if is two blocks deep" <<'EOF'
f() {
  for x in y; do :; done
  if a; then if b; then :; fi; fi
  x=1 && while c; do :; done
}
EOF

t_case "a backslash-escaped quote neither ends nor starts a string"
fix="$(_tree <<'EOF'
f() {
  echo "a \" || b || c \" d"
  d && e
}
EOF
)"
t_assert_eq "2" "$(_measure "${fix}" f cc)" "everything between the outer quotes is text"
rm -rf "${fix}"
fix="$(_tree <<'EOF'
f() {
  echo \' a || b
  c && d
}
EOF
)"
t_assert_eq "3" "$(_measure "${fix}" f cc)" "\\' is a literal quote, not an open string"
rm -rf "${fix}"

t_case "arithmetic is not a heredoc: << inside (( )) swallows nothing"
_pins 3 1 "1 + if + ||; the shifts are arithmetic" "the lines after the shift still parse" <<'EOF'
f() {
  x=$(( a << b ))
  if (( c << d )); then :; fi
  e || g
}
EOF

t_case "the '}' that closes \${x:-\$(cmd)} is not a block end"
_pins 2 1 "one real if" "an undelimited '}' must not close the body" <<'EOF'
f() {
  a=${x:-$(cmd)}
  if b; then :; fi
}
EOF

# ── command position: one case per CMD_OPS member ────────────────────────────
t_case "a newline opens command position"
_pins 2 1 "the if that starts a line is a branch" <<'EOF'
f() {
  echo hi
  if a; then :; fi
}
EOF

t_case "';' opens command position"
_pins 2 1 "x=1; if ... is a branch, not an argument word" <<'EOF'
f() {
  x=1; if a; then :; fi; echo done
}
EOF

t_case "';;' opens command position"
_pins 3 1 "the esac after an arm terminator really closes the case" <<'EOF'
f() {
  case "$1" in a) : ;; esac
  case "$2" in b) : ;; esac
}
EOF

t_case "';&' opens command position"
_pins 3 1 "a fallthrough arm still ends its case at the esac" <<'EOF'
f() {
  case "$1" in a) : ;& esac
  case "$2" in b) : ;; esac
}
EOF

t_case "';;&' opens command position"
_pins 3 1 "a retry arm still ends its case at the esac" <<'EOF'
f() {
  case "$1" in a) : ;;& esac
  case "$2" in b) : ;; esac
}
EOF

t_case "'&&' opens command position"
_pins 3 1 "a && if ... fi is a nested branch" <<'EOF'
f() {
  a && if b; then :; fi
}
EOF

t_case "'||' opens command position"
_pins 3 1 "a || if ... fi is a nested branch" <<'EOF'
f() {
  a || if b; then :; fi
}
EOF

t_case "'|' opens command position"
_pins 2 1 "a pipe-fed while loop is a loop" <<'EOF'
f() {
  a | while read -r x; do :; done
}
EOF

t_case "'&' opens command position"
_pins 2 1 "the command after a backgrounded one still counts" <<'EOF'
f() {
  a & if b; then :; fi
}
EOF

t_case "'(' opens command position"
_pins 2 1 "a subshell's first word is a command" <<'EOF'
f() {
  ( if a; then :; fi )
}
EOF

t_case "'\$(' opens command position"
_pins 2 1 "a substitution's first word is a command" <<'EOF'
f() {
  v=$(if a; then echo 1; fi)
}
EOF

t_case "'{' opens command position"
_pins 2 2 "a brace group's first word is a command" <<'EOF'
f() {
  { if a; then :; fi; } >/dev/null
}
EOF

# ── `((` is arithmetic only after a delimiter: one case per member ───────────
t_case "'((' after a space is arithmetic, not a heredoc"
_pins 3 1 "the << is a shift and the line after it still counts" <<'EOF'
f() {
  if (( x << n )); then :; fi
  a || b
}
EOF

t_case "'((' after a tab is arithmetic, not a heredoc"
_pins 2 0 "a tab-indented shift must not swallow the rest of the function" <<'EOF'
f() {
	(( x = y << n ))
	a || b
}
EOF

t_case "'((' after a ';' is arithmetic, not a heredoc"
_pins 2 0 "x=1;((...)) is a shift, not a heredoc" <<'EOF'
f() {
  x=1;((y << n))
  a || b
}
EOF

t_case "'((' after a '(' is arithmetic, not a heredoc"
_pins 2 0 "the arithmetic inside a <(( ... )) still parses" <<'EOF'
f() {
  cat <(((x << n)))
  a || b
}
EOF

t_case "'((' after a '|' is arithmetic, not a heredoc"
_pins 2 0 "an arithmetic command on the right of a pipe still parses" <<'EOF'
f() {
  true|((x << n))
  a || b
}
EOF

t_case "'((' after a '&' is arithmetic, not a heredoc"
_pins 2 0 "the arithmetic after a backgrounded job still parses" <<'EOF'
f() {
  sleep 1 &((x << n))
  a || b
}
EOF

t_case "'((' at column 0 is arithmetic: a line start is a delimiter too"
_pins 2 0 "nothing precedes it, so its << must not swallow the rest" <<'EOF'
f() {
((x << n))
  a || b
}
EOF

# ── a '}' is a block end only when something delimits it ─────────────────────
t_case "a '}' glued to a ';' still closes its block"
_pins 3 2 "'{ : ;}' ends the brace group; unclosed, everything after it reads one deeper" <<'EOF'
f() {
  { : ;}
  if a; then
    if b; then
      :
    fi
  fi
}
EOF

# ── the four-way contract, both metrics ──────────────────────────────────────
t_case "under both limits nothing is reported"
t_assert_contains "$(_run_on _ors 14)" "rc=0" "cc 15 is at, not over, the limit"
t_assert_contains "$(_run_on _deep 5)" "rc=0" "nesting 5 is at, not over, the limit"

t_case "cc: new offender / frozen / grew / shrank / stale"
_contract _ors 19 2 cc 20 paths 15-path

t_case "nesting: new offender / frozen / grew / shrank / stale"
_contract _deep 7 2 nesting 7 levels 5-level

t_case "a row for one metric does not cover the other"
out="$(_run_on _deep 7 "${ROW} | cc | 8 | baseline")"
t_assert_contains "${out}" "f:nesting is 7 levels" "nesting is unfrozen even though cc is listed"
t_assert_contains "${out}" "rc=1"

t_case "the limits are env knobs"
fix="$(_ors 3 | _tree)"
t_assert_contains "$(COMPLEXITY_LIMIT=3 _gate "${fix}")" "over the 3-path limit"
rm -rf "${fix}"

t_case "an allow row that does not name a known metric fails loudly"
out="$(_run_on _ors 19 "${ROW} | cc | 20 | baseline" "${ROW} | CC | 20 | baseline")"
t_assert_contains "${out}" "row 'linux/scripts/subject.sh | f | CC' must name a metric column"
t_assert_contains "${out}" "rc=1" "an unknown metric name must not be silently ignored"
out="$(_run_on _ors 19 "${ROW} | cc | 20 | baseline" "linux/scripts/other.sh | g | 20 | baseline")"
t_assert_contains "${out}" "row 'linux/scripts/other.sh | g' must name a metric column"
t_assert_contains "${out}" "nesting:" "a row missing the metric column must not crash the gate"

t_case "the REAL tree is clean today"
t_assert_eq "0" "$( "${PY}" "${SRC}/${GATE}" >/dev/null 2>&1; echo $? )"

t_summary
