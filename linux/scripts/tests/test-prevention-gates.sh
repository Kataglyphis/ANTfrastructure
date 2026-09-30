#!/usr/bin/env bash
# comment-size and masked-decls, each copied into a fixture tree; see docs/code-quality-tooling.md#proving-a-gate-can-go-red
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
PY="${PREFLIGHT_PYTHON:-python3}"
S="${TESTS_DIR}/.."

OVER="$(printf '# note 1\n# note 2\n:')"
FITS="$(printf '# note 1\n:')"
# printf, not a literal: a real masked `local` line here would be an offender itself.
MASKED="$(printf 'f() {\n  local x="$(date)"\n  echo "${x}"\n}')"
SPLIT="$(printf 'f() {\n  local x\n  local y="plain"\n  x="$(date)" || return 1\n  echo "${x}${y}"\n}')"
COMMENT_KEY=$'linux/scripts/subject.sh\t# note 1'
MASKED_KEY=$'linux/scripts/subject.sh\tx'
SUBJ_PATH="linux/scripts/subject.sh"

# _verdict <gate.py> <allow-name> <subject> [frozen row...] -> output plus `rc=<n>`; the subject lands at ${SUBJ_PATH}.
_verdict() {
  local d out rc
  d="$(mktemp -d)"
  mkdir -p "${d}/linux/scripts" "${d}/$(dirname "${SUBJ_PATH}")"
  # The gates import gate_scope.py; without it a fixture gets a traceback, not a verdict.
  cp "${S}/$1" "${S}/quality_allow.py" "${S}/gate_scope.py" "${d}/linux/scripts/"
  printf '%s\n' "$3" > "${d}/${SUBJ_PATH}"
  [ "$#" -lt 4 ] || printf '%s\n' "${@:4}" > "${d}/linux/scripts/$2"
  # Tracked, because the comment gate grades only what git tracks.
  { git -C "${d}" init -q && git -C "${d}" add -A; } >/dev/null 2>&1 || true
  out="$("${PY}" "${d}/linux/scripts/$1" 2>&1)"; rc=$?
  rm -rf "${d}"
  printf '%s\nrc=%s\n' "${out}" "${rc}"
}
_size()   { _verdict verify_comment_size.py comment-size.allow "$@"; }
_masked() { _verdict verify_masked_assignments.py masked-assignments.allow "$@"; }
# _size_at <path> <content>: one subject at another path, in another language.
_size_at() { local SUBJ_PATH="$1"; _size "$2"; }

# _freeze_contract <fn> <offender> <clean> <frozen row>: the frozen offender passes; the row over the clean one is STALE.
_freeze_contract() {
  local out
  t_assert_contains "$("$1" "$2" "$4")" "rc=0" "frozen at its own key it passes"
  out="$("$1" "$3" "$4")"
  t_assert_contains "${out}" "STALE entr" "the offender is gone"
  t_assert_contains "${out}" "rc=1" "a stale freeze is a failure, not a warning"
}

# The gate grades tracked files, and the mutation gate's copy has no .git.
if git -C "${S}" rev-parse --git-dir >/dev/null 2>&1; then
  t_case "the gate passes on the frozen tree"
  t_assert_ok "${PY}" "${S}/verify_comment_size.py"
fi

t_case "it is registered in preflight"
t_assert_contains "$(cat "${S}/preflight.sh")" "comment-size" "an unwired gate is not a gate"

t_case "a key that truncates onto whitespace still survives the allowlist"
# A key cut onto a space is stripped by the allowlist reader, making the block NEW and STALE at once.
t_assert_contains "$(cat "${S}/verify_comment_size.py")" ".rstrip()" \
  "truncate first, then rstrip"

t_case "the comment allowlist keys on text, not line number"
t_assert_eq "0" "$(grep -c -E '\t[0-9]+$' "${S}/comment-size.allow")" \
  "a line number would re-flag every block whenever something above it moves"

t_case "a two-line comment block fails, and says where"
_out="$(_size "${OVER}")"
t_assert_contains "${_out}" "NEW comment block(s) over the limit" "the heading names the class"
t_assert_contains "${_out}" "linux/scripts/subject.sh:1  2 lines" "file, start line and size"
t_assert_contains "${_out}" "rc=1" "printing the block is not enough; it must exit non-zero"

t_case "a one-line comment passes"
_out="$(_size "${FITS}")"
t_assert_contains "${_out}" "OK: no new oversized comment blocks"
t_assert_contains "${_out}" "rc=0" "one line is the rule, not an offence"

t_case "a frozen block passes, and a stale freeze fails"
_freeze_contract _size "${OVER}" "${FITS}" "${COMMENT_KEY}"

t_case "licence headers and tool directives are not prose"
_out="$(_size "$(printf '#!/usr/bin/env bash\n# Copyright (c) 2025 Kataglyphis\n# SPDX-License-Identifier: MIT\n# why\n# shellcheck disable=SC2034\n:')")"
t_assert_contains "${_out}" "rc=0" "a header plus one why-line plus a directive is one comment"

t_case "a heredoc body is data, and a quoted << opens none"
t_assert_contains "$(_size "$(printf 'cat <<EOF\n# a\n# b\nEOF')")" "rc=0" "heredoc lines are not comments"
t_assert_contains "$(_size "$(printf 'printf "a<<b"\n# c1\n# c2\n:')")" "rc=1" \
  "a << inside quotes must not hide the block after it"

t_case "every language: PowerShell, with its here-strings as data"
t_assert_contains "$(_size_at windows/scripts/subject.ps1 "$(printf '# a\n# b\n$x = 1')")" "rc=1" "a PowerShell block fails"
t_assert_contains "$(_size_at windows/scripts/subject.ps1 "$(printf '$x = @"\n# a\n# b\n"@')")" "rc=0" \
  "here-string lines are not comments"
t_assert_contains "$(_size_at windows/scripts/subject.ps1 "$(printf "\$h = 'it''s\n#define a b\n#define c d'\n# e\n# f")")" "rc=1" \
  "a multi-line string is data, and a block after it still counts"

t_case "every language: Python, with its strings as data"
t_assert_contains "$(_size_at docs/scripts/subject.py "$(printf '# a\n# b\nx = 1')")" "rc=1" "a Python block fails"
t_assert_contains "$(_size_at docs/scripts/subject.py "$(printf 'x = """\n# a\n# b\n"""')")" "rc=0" \
  "a string is not a comment"

t_case "every language: C family, where /* */ counts and /// API docs do not"
t_assert_contains "$(_size_at src/subject.cpp "$(printf '/* a\n   b */\nint y;')")" "rc=1" "a block comment fails"
t_assert_contains "$(_size_at src/subject.rs "$(printf '/// a\n/// b\nfn f() {}')")" "rc=0" "API docs stay"

t_case "a masked declaration fails, and says which variable"
_out="$(_masked "${MASKED}")"
t_assert_contains "${_out}" "NEW masked declaration" "the heading names the class"
t_assert_contains "${_out}" "linux/scripts/subject.sh:2  x" "file, line and variable"
t_assert_contains "${_out}" "rc=1" "printing the site is not enough; it must exit non-zero"

t_case "the split form passes, and so does a literal-valued declaration"
_out="$(_masked "${SPLIT}")"
t_assert_contains "${_out}" "OK: no new masked declarations"
t_assert_contains "${_out}" "  0 \`local/export x=\$(...)\` site(s)" \
  "a declaration with no command substitution masks nothing"
t_assert_contains "${_out}" "rc=0" "declare first, assign second, check the status"

t_case "a frozen site passes, and a stale freeze fails"
_freeze_contract _masked "${MASKED}" "${SPLIT}" "${MASKED_KEY}"

t_case "the REAL scan set covers every language and linux/llm-stack -- EX1"
# Only this probe sees the shipped scan set; it reads PATTERNS, as the mutation gate's copy is no git checkout.
_ex1_probe="$(t_gate_probe linux/scripts/verify_comment_size.py <<'PYCHK'
import fnmatch
want = ["linux/llm-stack/scripts/download-ollama.sh", "windows/scripts/build/Build-TorchRocmFromSource.ps1",
        "linux/scripts/verify_comment_size.py", "windows/Dockerfile.torch", ".github/workflows/linux-x64.yml"]
missing = [w for w in want if not (any(fnmatch.fnmatchcase(w, p) for p in g.PATTERNS)
                                   and g.style(w) and not g.SKIP.search(w))]
print("scanned" if not missing else f"MISSING {missing}")
PYCHK
)"
t_assert_eq "scanned" "${_ex1_probe}" \
  "a language or tree dropped from the scan leaves its comments ungated"

t_summary
