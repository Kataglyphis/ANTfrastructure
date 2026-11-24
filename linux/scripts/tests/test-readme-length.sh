#!/usr/bin/env bash
# verify_readme_length.py over fixture repos and a fixture hub, and its run-lint-gates.sh half; -k <section> picks cases. See docs/code-quality-tooling.md#readme-length-readme-length
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SCRIPTS="$(cd "${TESTS_DIR}/.." && pwd)"
GATE="${SCRIPTS}/verify_readme_length.py"
PY="${PREFLIGHT_PYTHON:-python3}"
_work="$(t_mktemp -d)"

# _repo <lines> [no-eol]: a git root whose README.md has that many lines; no-eol drops the last newline.
_repo() {
  local d; d="$(mktemp -d "${_work}/repo.XXXXXX")"
  seq -f 'line %g' 1 "$1" > "${d}/README.md"
  [ "${2-}" != no-eol ] || printf 'one more line' >> "${d}/README.md"
  git -C "${d}" init -q && git -C "${d}" -c core.autocrlf=false add -A
  printf '%s' "${d}"
}

# _words <count>: that many words, ten to a line, so no line gets wide.
_words() {
  local i
  for ((i = 1; i <= $1; i++)); do
    printf 'word'
    if ((i % 10 == 0 || i == $1)); then printf '\n'; else printf ' '; fi
  done
}

# _wide <characters>: one line of exactly that width, one word long.
_wide() { printf '%*s\n' "$1" '' | tr ' ' x; }

# _over <repo>: a README over the word and the width limit, 801 words and one line of 200 characters.
_over() { { _words 800; _wide 200; } > "$1/README.md"; }

# _seeded <repo>: an empty census, so the README meets the fixed limits.
_seeded() { : > "$1/readme-length.census"; }

_grade() { "${PY}" "${GATE}" --root "$@"; }

_section_lines() {
  local d
  t_case "100 lines, badges included, is the limit and passes"
  d="$(_repo 100)"
  t_assert_eq 0 "$(t_rc _grade "${d}")" "the rule allows 100 lines"
  t_assert_contains "$(t_out _grade "${d}")" "README.md is 100 lines"

  t_case "101 lines fail, and the message names the rule and its page"
  d="$(_repo 101)"
  t_assert_eq 1 "$(t_rc _grade "${d}")" "one line over the limit fails"
  t_assert_contains "$(t_out _grade "${d}")" "README.md is 101 lines"
  t_assert_contains "$(t_out _grade "${d}")" "the README rule"
  t_assert_contains "$(t_out _grade "${d}")" "docs/repository-family.md#the-readme-rule"

  t_case "a last line without a newline still counts"
  t_assert_eq 1 "$(t_rc _grade "$(_repo 100 no-eol)")" "100 lines plus an unterminated one is 101"

  t_case "no README.md, or no git root, is not a pass"
  d="$(mktemp -d "${_work}/bare.XXXXXX")"
  printf 'x\n' > "${d}/other.md"
  git -C "${d}" init -q
  t_assert_eq 1 "$(t_rc _grade "${d}")" "every repository has a README; a missing one is not short"
  t_assert_contains "$(t_out _grade "${d}")" "every repository has one" "a verdict, not a traceback"
  t_assert_eq 2 "$(t_rc _grade "${_work}")" "a root that is no git checkout grades nothing"
}

_section_words() {
  local d
  t_case "700 words pass and 701 fail once the census exists"
  d="$(_repo 0)"
  _seeded "${d}"
  _words 700 > "${d}/README.md"
  t_assert_rc 0 _grade "${d}"
  t_assert_contains "$(_grade "${d}")" "README.md is 70 lines, 700 words, 0 line(s) over 160 characters"
  _words 701 > "${d}/README.md"
  t_assert_rc 1 _grade "${d}"
  t_assert_contains "$(_grade "${d}" 2>&1)" "words is 701, over the 700 a README without a row may have"

  t_case "a token without a letter or digit is no word"
  { _words 700; printf '| --- | --- |\n· — ## * -\n'; } > "${d}/README.md"
  t_assert_rc 0 _grade "${d}"
}

_section_width() {
  local d
  t_case "a line of 160 characters passes, 161 fail, and the line is named"
  d="$(_repo 0)"
  _seeded "${d}"
  { printf 'Title\n'; _wide 160; } > "${d}/README.md"
  t_assert_rc 0 _grade "${d}"
  { printf 'Title\n'; _wide 161; } > "${d}/README.md"
  t_assert_rc 1 _grade "${d}"
  t_assert_contains "$(_grade "${d}" 2>&1)" "long-lines is 1, over the 0"
  t_assert_contains "$(_grade "${d}" 2>&1)" "README.md:2: 161 characters"

  t_case "badge lines and a line that is one link are exempt, from width and from words"
  local url badge
  url="https://example.invalid/$(_wide 150)"
  badge="[![CI one](${url}/badge.svg)](${url}) [![CI two](${url}/badge.svg)](${url})"
  { _words 700; printf '%s\n![alone](%s)\n[%s](%s)\n- [listed](%s)\n<%s>\n%s\n[ref]: %s\n' \
      "${badge}" "${url}" "a long link text" "${url}" "${url}" "${url}" "${url}" "${url}"; } > "${d}/README.md"
  t_assert_rc 0 _grade "${d}"
  printf 'See [a link](%s) here.\n' "${url}" >> "${d}/README.md"
  t_assert_rc 1 _grade "${d}"
  t_assert_contains "$(_grade "${d}" 2>&1)" "words is 704, over the 700"
}

_section_ratchet() {
  local d
  t_case "a seed writes a row for each figure over its limit, and the README passes"
  d="$(_repo 0)"
  _over "${d}"
  t_assert_rc 0 _grade "${d}" --seed
  t_assert_grep "${d}/readme-length.census" '^README.md \| words \| 801$'
  t_assert_grep "${d}/readme-length.census" '^README.md \| long-lines \| 1$'
  t_assert_grep "${d}/readme-length.census" '^README.md \| overflow \| 40$'
  t_assert_rc 0 _grade "${d}"

  t_case "a grown figure fails, and --write never raises its row"
  printf 'more\n' >> "${d}/README.md"
  t_assert_rc 1 _grade "${d}"
  t_assert_contains "$(_grade "${d}" 2>&1)" "words grew from 801 to 802"
  t_assert_rc 1 _grade "${d}" --write
  t_assert_grep "${d}/readme-length.census" '^README.md \| words \| 801$'
  { _words 800; _wide 201; } > "${d}/README.md"
  t_assert_contains "$(_grade "${d}" 2>&1)" "overflow grew from 40 to 41"

  t_case "a fallen figure fails until --write lowers its row"
  { _words 750; _wide 200; } > "${d}/README.md"
  t_assert_contains "$(_grade "${d}" 2>&1)" "words fell from 801 to 751; lower its row in this commit"
  t_assert_rc 0 _grade "${d}" --write
  t_assert_grep "${d}/readme-length.census" '^README.md \| words \| 751$'

  t_case "a row at its limit goes with --write, and the limit binds again"
  { _words 600; _wide 200; } > "${d}/README.md"
  t_assert_rc 0 _grade "${d}" --write
  t_assert_no_grep "${d}/readme-length.census" '^README.md \| words'
  _words 701 >> "${d}/README.md"
  t_assert_contains "$(_grade "${d}" 2>&1)" "words is 1302, over the 700"

  t_case "a row of another page, or at its limit, holds nothing and fails until --write deletes it"
  _words 600 > "${d}/README.md"
  printf 'guide/other.md | words | 900\nREADME.md | long-lines | 0\n' > "${d}/readme-length.census"
  t_assert_rc 1 _grade "${d}"
  t_assert_contains "$(_grade "${d}" 2>&1)" "guide/other.md: the words row holds nothing"
  t_assert_contains "$(_grade "${d}" 2>&1)" "README.md: the long-lines row holds nothing"
  t_assert_rc 0 _grade "${d}" --write
  t_assert_no_grep "${d}/readme-length.census" '^[^#]'

  t_case "a malformed census and a second --seed are refused, not read"
  printf 'README.md | words\n' > "${d}/readme-length.census"
  t_assert_rc 2 _grade "${d}"
  t_assert_rc 2 _grade "${d}" --seed
}

_section_consumer() {
  local d
  t_case "the line limit binds without a census"
  t_assert_rc 1 _grade "$(_repo 101)"

  t_case "a consumer without a census is reported, not failed, until it seeds one"
  d="$(_repo 0)"
  _over "${d}"
  t_assert_rc 0 _grade "${d}"
  t_assert_contains "$(_grade "${d}")" "words and width OFF for ${d} until readme-length.census exists"
  t_assert_contains "$(_grade "${d}")" "README.md is 81 lines, 801 words, 1 line(s) over 160 characters"

  t_case "a seed of a README within the limits writes no row, and the limits bind"
  _words 600 > "${d}/README.md"
  t_assert_rc 0 _grade "${d}" --seed
  t_assert_no_grep "${d}/readme-length.census" '^[^#]'
  _wide 161 >> "${d}/README.md"
  t_assert_rc 1 _grade "${d}"
}

_section_hub() {
  local hub
  t_case "the hub's own census is required"
  hub="$(t_gate_tree verify_readme_length.py verify_doc_prose.py gate_scope.py verify_comment_size.py quality_allow.py)"
  git -C "${hub}" init -q
  _words 100 > "${hub}/README.md"
  t_assert_rc 2 "${PY}" "${hub}/linux/scripts/verify_readme_length.py"
  t_assert_contains "$("${PY}" "${hub}/linux/scripts/verify_readme_length.py" 2>&1)" "the hub grades its README against it"
  mkdir -p "${hub}/docs/scripts"
  : > "${hub}/docs/scripts/readme-length.census"
  t_assert_rc 0 "${PY}" "${hub}/linux/scripts/verify_readme_length.py"
  _words 701 > "${hub}/README.md"
  t_assert_rc 1 "${PY}" "${hub}/linux/scripts/verify_readme_length.py"
  rm -rf "${hub}"
}

_section_wiring() {
  local d
  t_case "run-lint-gates.sh grades the consumer's README with the same gate"
  # shellcheck source=../run-lint-gates.sh
  source "${SCRIPTS}/run-lint-gates.sh"
  _lint_gates_parse_args "$(_repo 101)"
  t_assert_eq 1 "$(t_rc _lint_gates_readme)" "a consumer README over the limit fails the aggregator"
  _lint_gates_parse_args "$(_repo 60)"
  t_assert_eq 0 "$(t_rc _lint_gates_readme)" "a short one passes"
  d="$(_repo 0)"
  _words 701 > "${d}/README.md"
  _lint_gates_parse_args "${d}"
  t_assert_eq 0 "$(t_rc _lint_gates_readme)" "an unseeded consumer over the word limit is reported only"
  _seeded "${d}"
  t_assert_eq 1 "$(t_rc _lint_gates_readme)" "a seeded one fails the aggregator"
  t_assert_contains "$(cat "${SCRIPTS}/run-lint-gates.sh")" 'run_gate "README length" _lint_gates_readme'
}

t_sections _section_lines _section_words _section_width _section_ratchet _section_consumer _section_hub \
  _section_wiring -- "$@"
t_summary
