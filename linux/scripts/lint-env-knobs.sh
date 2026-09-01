#!/usr/bin/env bash
# lint-env-knobs.sh — A1: the env-knob registry gate (verify-arg-consistency
# family). Every ALL_CAPS knob CONSUMED via `${VAR:-default}` in linux/scripts
# must have an OWNER:
#   (a) set in versions.env,                          — pinned config
#   (b) declared as ARG/ENV in a linux/Dockerfile*,   — build-graph plumbed
#   (c) assigned/exported somewhere in linux/scripts, — derived internally
#   (d) listed in lint-env-knobs.allow                — documented OPERATOR knob
# Anything else is an UNOWNED knob: a typo'd fallback, a dead alias, or an
# undocumented operator switch — exactly the class A1 exists to catch (the
# UBUNTU_PORTS_MIRROR_URL dead-alias was one).
#
# ADVISORY by default (never fails); KNOB_GATE=1 promotes unowned knobs to a
# hard failure. The allowlist doubles as the operator-knob documentation.
set -uo pipefail
export LC_ALL=C

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPTS="${REPO_ROOT}/linux/scripts"
ALLOW="${SCRIPTS}/lint-env-knobs.allow"
VERSIONS_ENV="${SCRIPTS}/01-core/versions.env"

echo "=== env-knob registry gate (A1; advisory unless KNOB_GATE=1) ==="

_tmp="$(mktemp -d)"
trap 'rm -rf "${_tmp}"' EXIT

# 1) CONSUMED knobs: ${VAR:-...} readers in shell scripts. Skip _-prefixed
#    (privates by convention) and 1-2 char names (loop vars).
grep -rhoE '\$\{[A-Z][A-Z0-9_]{2,}:-' "${SCRIPTS}" --include='*.sh' 2>/dev/null \
  | sed -E 's/^\$\{//; s/:-$//' | LC_ALL=C sort -u | grep -vE '^_' \
  | grep -vE '^(BASH_SOURCE|BASH_REMATCH|HOME|PATH|PWD|OLDPWD|HOSTNAME|OSTYPE|EUID|UID|USER|SHELL|LANG|LC_ALL|TERM|TMPDIR|IFS|PPID|RANDOM|SECONDS|LINENO|FUNCNAME|COLUMNS|LINES|XDG_[A-Z_]+)$' \
  > "${_tmp}/consumed"

# 2) OWNERS
#    (a) versions.env keys
sed -nE 's/^([A-Z][A-Z0-9_]+)=.*/\1/p' "${VERSIONS_ENV}" 2>/dev/null | LC_ALL=C sort -u > "${_tmp}/own_versions"
#    (b) Dockerfile ARG/ENV declarations
grep -rhoE '^\s*(ARG|ENV)\s+[A-Z][A-Z0-9_]+' "${REPO_ROOT}"/linux/Dockerfile* 2>/dev/null \
  | awk '{print $2}' | LC_ALL=C sort -u > "${_tmp}/own_dockerfile"
#    (c) script-side assignments/exports (VAR= / export VAR= / declare VAR= /
#        : "${VAR:=...}" self-defaulting / read into VAR)
{ grep -rhoE '(^|[^A-Za-z0-9_{])[A-Z][A-Z0-9_]{2,}=' "${SCRIPTS}" --include='*.sh' 2>/dev/null \
    | grep -oE '[A-Z][A-Z0-9_]{2,}='
  grep -rhoE ':\s*"\$\{[A-Z][A-Z0-9_]{2,}:=' "${SCRIPTS}" --include='*.sh' 2>/dev/null \
    | grep -oE '[A-Z][A-Z0-9_]{2,}'
} | tr -d '=' | LC_ALL=C sort -u > "${_tmp}/own_scripts"
#    (d) allowlist (strip comments/blanks)
if [ -f "${ALLOW}" ]; then
  sed -E 's/#.*$//; s/[[:space:]]+//g' "${ALLOW}" | grep -vE '^$' | LC_ALL=C sort -u > "${_tmp}/own_allow"
else
  : > "${_tmp}/own_allow"
fi

LC_ALL=C sort -u "${_tmp}/own_versions" "${_tmp}/own_dockerfile" "${_tmp}/own_scripts" "${_tmp}/own_allow" > "${_tmp}/owned"

# 3) verdict
comm -23 "${_tmp}/consumed" "${_tmp}/owned" > "${_tmp}/unowned"
n_consumed="$(wc -l < "${_tmp}/consumed")"
n_unowned="$(wc -l < "${_tmp}/unowned")"
echo "  consumed \${VAR:-} knobs: ${n_consumed} | owners: versions.env=$(wc -l < "${_tmp}/own_versions") dockerfiles=$(wc -l < "${_tmp}/own_dockerfile") scripts=$(wc -l < "${_tmp}/own_scripts") allowlist=$(wc -l < "${_tmp}/own_allow")"

if [ "${n_unowned}" -eq 0 ]; then
  echo "  OK: every consumed knob has an owner (versions.env / Dockerfile ARG-ENV / script assignment / allowlist)"
  exit 0
fi

echo "  UNOWNED knobs (${n_unowned}) — typo'd fallback, dead alias, or undocumented operator switch:"
sed 's/^/    /' "${_tmp}/unowned"
echo "  -> either fix the reader, or document the knob in $(basename "${ALLOW}") (one per line + comment)."
if [ "${KNOB_GATE:-0}" = "1" ]; then
  echo "FAIL: ${n_unowned} unowned env knob(s) (KNOB_GATE=1)." >&2
  exit 1
fi
echo "  (advisory — set KNOB_GATE=1 to enforce)"
exit 0
