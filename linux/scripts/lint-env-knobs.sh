#!/usr/bin/env bash
# lint-env-knobs.sh — A1: every `${VAR:-default}` knob consumed in linux/scripts
# needs an owner: versions.env, a Dockerfile ARG/ENV, a script assignment in
# command position, or a row in lint-env-knobs.allow. Unowned knobs are advisory
# unless KNOB_GATE=1; a STALE allow row (knob consumed nowhere) always fails.
# docs/code-quality-tooling.md#contract-tightening-2026-09-03-code-dupes-env-knobs
set -uo pipefail
export LC_ALL=C

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPTS="${REPO_ROOT}/linux/scripts"
ALLOW="${SCRIPTS}/lint-env-knobs.allow"
VERSIONS_ENV="${SCRIPTS}/01-core/versions.env"

echo "=== env-knob registry gate (A1; unowned advisory unless KNOB_GATE=1, stale always fails) ==="

_tmp="$(mktemp -d)"
trap 'rm -rf "${_tmp}"' EXIT

# ONE walker for both passes over linux/scripts/*.sh. It tracks single quotes,
# double quotes, $( ) and heredoc bodies so a `#` only ends the line when it
# really opens a comment. Default mode prints the ASSIGNMENTS in command
# position (quoted text and heredoc bodies own nothing); MODE=prefix prints the
# raw line up to that comment, which is what a knob READER needs -- a flat sed
# cut at ` #` loses every reader to the right of a hash inside a string.
_KNOB_AWK='
BEGIN { SQ = "\047" }
FNR == 1 { nhd = 0 }
{
  if (nhd > 0) { t = $0; if (hdtab[1]) sub(/^\t+/, "", t); if (t == hdend[1]) hdpop(); next }
  out = ""; top = 0; S[0] = "code"; P[0] = 0
  for (i = 1; i <= length($0); i++) {
    c = substr($0, i, 1)
    if (S[top] == "sq") { if (c == SQ) top--; continue }
    if (S[top] == "dq") {
      if (c == "\\") i++
      else if (c == "\"") top--
      else if (c == "$" && substr($0, i + 1, 1) == "(") { top++; S[top] = "code"; P[top] = 0; out = out "$("; i++ }
      continue
    }
    if (MODE != "prefix" && c == "<" && substr($0, i + 1, 1) == "<") { i = hdpush(i); continue }
    if (c == "\\") { i++; continue }
    if (c == SQ) { top++; S[top] = "sq"; continue }
    if (c == "\"") { top++; S[top] = "dq"; continue }
    if (c == "#" && (out == "" || substr(out, length(out), 1) ~ /[ \t]/)) break
    if (c == "(") P[top]++
    else if (c == ")") { if (P[top] > 0) { P[top]--; continue } else if (top > 0) { top--; continue } }
    out = out c
  }
  if (MODE == "prefix") { print substr($0, 1, i - 1); next }
  pos = 1
  while (match(substr(out, pos), /[A-Z][A-Z0-9_][A-Z0-9_]+=/)) {
    q = pos + RSTART - 1; l = RLENGTH
    prev = (q == 1) ? "" : substr(out, q - 1, 1)
    if (prev !~ /[A-Za-z0-9_{]/ && cmdpos(substr(out, 1, q - 1))) print substr(out, q, l - 1)
    pos = q + l
  }
}
function hdpush(i,   j, d, qc) {
  j = i + 2; nhd++; hdtab[nhd] = (substr($0, j, 1) == "-"); if (hdtab[nhd]) j++
  while (substr($0, j, 1) ~ /^[ \t]$/) j++
  qc = substr($0, j, 1); if (qc == "\\") { j++; qc = "" }
  if (qc == SQ || qc == "\"") { j++; while (j <= length($0) && substr($0, j, 1) != qc) { d = d substr($0, j, 1); j++ }; j++ }
  else { while (substr($0, j, 1) ~ /^[A-Za-z0-9_]$/) { d = d substr($0, j, 1); j++ }; if (d !~ /^[A-Za-z_]/) d = "" }
  if (d == "") { nhd--; out = out "<<"; return i + 1 }
  hdend[nhd] = d; return j - 1
}
function hdpop(   k) { for (k = 1; k < nhd; k++) { hdend[k] = hdend[k + 1]; hdtab[k] = hdtab[k + 1] } nhd-- }
function cmdpos(pre,   w) {
  sub(/[ \t]+$/, "", pre)
  if (pre == "") return 1
  if (pre ~ /[;&|(){]$/) return 1
  while (pre ~ /(^|[ \t])-[A-Za-z-]+$/) { sub(/[ \t]*-[A-Za-z-]+$/, "", pre); if (pre == "") return 0 }
  w = pre; sub(/^.*[ \t]/, "", w)
  if (w ~ /^(then|else|elif|do|if|while|until|export|local|declare|readonly|typeset|env|time|!)$/) return 1
  if (w !~ /^[A-Za-z_][A-Za-z0-9_]*=/) return 0
  return cmdpos(substr(pre, 1, length(pre) - length(w)))
}'

# Line-oriented scan of linux/scripts/*.sh: $1 selects lines, $2 extracts. The one
# walker drops both comment forms and backslash-escaped \$, so neither prose nor
# literal output text is ever evidence of anything.
_scan() {
  grep -rhE "$1" "${SCRIPTS}" --include='*.sh' 2>/dev/null \
  | awk -v MODE=prefix "${_KNOB_AWK}" \
  | sed -E 's/\\\$/\\/g' \
  | grep -oE "$2"
}

# 1) CONSUMED knobs: ${VAR:-...} readers. The selector is deliberately loose;
#    the EXTRACT regex is the promise — [A-Z] first bars _-prefixed privates.
_scan '\$\{[A-Za-z_][A-Za-z0-9_]*:-' '\$\{[A-Z][A-Z0-9_]{2,}:-' \
  | sed -E 's/^\$\{//; s/:-$//' | LC_ALL=C sort -u \
  | grep -vE '^(BASH_SOURCE|BASH_REMATCH|HOME|PATH|PWD|OLDPWD|HOSTNAME|OSTYPE|EUID|UID|USER|SHELL|LANG|LC_ALL|TERM|TMPDIR|IFS|PPID|RANDOM|SECONDS|LINENO|FUNCNAME|COLUMNS|LINES|XDG_[A-Z_]+)$' \
  > "${_tmp}/consumed"

# 2) OWNERS
#    (a) versions.env keys
sed -nE 's/^([A-Z][A-Z0-9_]+)=.*/\1/p' "${VERSIONS_ENV}" 2>/dev/null | LC_ALL=C sort -u > "${_tmp}/own_versions"
#    (b) Dockerfile ARG/ENV declarations
grep -rhoE '^\s*(ARG|ENV)\s+[A-Z][A-Z0-9_]+' "${REPO_ROOT}"/linux/Dockerfile* 2>/dev/null \
  | awk '{print $2}' | LC_ALL=C sort -u > "${_tmp}/own_dockerfile"
#    (c) script-side assignments in COMMAND position, plus the self-defaulting
#        : "${VAR:=...}" form. Quoted text, comments and heredoc bodies are not
#        code, so a NAME=value printed in a message owns nothing.
{ find "${SCRIPTS}" -name '*.sh' -print0 | LC_ALL=C sort -z | xargs -0 -r awk "${_KNOB_AWK}"
  _scan ':\s*"\$\{[A-Z][A-Z0-9_]{2,}:=' ':\s*"\$\{[A-Z][A-Z0-9_]{2,}:=' | grep -oE '[A-Z][A-Z0-9_]{2,}'
} | LC_ALL=C sort -u > "${_tmp}/own_scripts"
#    (d) allowlist (strip comments/blanks)
if [ -f "${ALLOW}" ]; then
  sed -E 's/#.*$//; s/[[:space:]]+//g' "${ALLOW}" | grep -vE '^$' | LC_ALL=C sort -u > "${_tmp}/own_allow"
else
  : > "${_tmp}/own_allow"
fi

LC_ALL=C sort -u "${_tmp}/own_versions" "${_tmp}/own_dockerfile" "${_tmp}/own_scripts" "${_tmp}/own_allow" > "${_tmp}/owned"

# 3) verdict (comm under LC_ALL=C like the sorts that fed it, or it disagrees silently)
LC_ALL=C comm -23 "${_tmp}/consumed" "${_tmp}/owned" > "${_tmp}/unowned"
LC_ALL=C comm -13 "${_tmp}/consumed" "${_tmp}/own_allow" > "${_tmp}/stale"
n_consumed="$(wc -l < "${_tmp}/consumed")"
n_unowned="$(wc -l < "${_tmp}/unowned")"
n_stale="$(wc -l < "${_tmp}/stale")"
echo "  consumed \${VAR:-} knobs: ${n_consumed} | owners: versions.env=$(wc -l < "${_tmp}/own_versions") dockerfiles=$(wc -l < "${_tmp}/own_dockerfile") scripts=$(wc -l < "${_tmp}/own_scripts") allowlist=$(wc -l < "${_tmp}/own_allow") | stale allow rows: ${n_stale}"

rc=0
if [ "${n_stale}" -gt 0 ]; then
  echo "  STALE allow rows (${n_stale}) — no \${VAR:-} reader consumes these any more; delete the row from $(basename "${ALLOW}"):"
  sed 's/^/    /' "${_tmp}/stale"
  echo "FAIL: ${n_stale} stale env-knob allow row(s) — bookkeeping error, fails regardless of KNOB_GATE." >&2
  rc=1
fi

if [ "${n_unowned}" -eq 0 ]; then
  if [ "${rc}" -eq 0 ]; then
    echo "  OK: every consumed knob has an owner (versions.env / Dockerfile ARG-ENV / script assignment / allowlist)"
  fi
  exit "${rc}"
fi

echo "  UNOWNED knobs (${n_unowned}) — typo'd fallback, dead alias, or undocumented operator switch:"
sed 's/^/    /' "${_tmp}/unowned"
echo "  -> either fix the reader, or document the knob in $(basename "${ALLOW}") (one per line + comment)."
if [ "${KNOB_GATE:-0}" = "1" ]; then
  echo "FAIL: ${n_unowned} unowned env knob(s) (KNOB_GATE=1)." >&2
  exit 1
fi
echo "  (advisory — set KNOB_GATE=1 to enforce)"
exit "${rc}"
