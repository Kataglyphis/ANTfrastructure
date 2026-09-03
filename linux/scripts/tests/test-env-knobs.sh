#!/usr/bin/env bash
# Tests for lint-env-knobs.sh. The gate derives its root from its own path, so it
# is copied into one throwaway tree (versions.env, a Dockerfile, one consumer
# script) whose allow file each case rewrites. KNOB_GATE is passed per run.
# docs/code-quality-tooling.md#contract-tightening-2026-09-03-code-dupes-env-knobs
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
LIVE="${TESTS_DIR}/../lint-env-knobs.sh"

_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT
mkdir -p "${_work}/linux/scripts/01-core"
cp "${LIVE}" "${_work}/linux/scripts/"
ALLOW="${_work}/linux/scripts/lint-env-knobs.allow"
SUBJECT="${_work}/linux/scripts/subject.sh"
printf 'PINNED_KNOB=1\n' > "${_work}/linux/scripts/01-core/versions.env"
printf 'FROM scratch\nARG DOCKER_KNOB\n' > "${_work}/linux/Dockerfile.subject"

# Consumers: every knob named is read via ${VAR:-} in the subject script.
_consume() { printf '#!/usr/bin/env bash\n'; printf 'echo "${%s:-}"\n' "$@"; }
_knobs()   { KNOB_GATE="${1:-0}" bash "${_work}/linux/scripts/lint-env-knobs.sh" 2>&1; }
_rc()      { KNOB_GATE="${1:-0}" bash "${_work}/linux/scripts/lint-env-knobs.sh" >/dev/null 2>&1; echo $?; }

t_case "a consumed knob owned by each owner kind passes, with zero stale rows"
_consume PINNED_KNOB DOCKER_KNOB OP_KNOB > "${SUBJECT}"
printf '# operator switch\nOP_KNOB\n' > "${ALLOW}"
t_assert_eq "0" "$(_rc)"
t_assert_eq "0" "$(_rc 1)"
t_assert_contains "$(_knobs)" "stale allow rows: 0"
t_assert_contains "$(_knobs)" "OK: every consumed knob has an owner"

t_case "an allow row whose knob is consumed nowhere is STALE and fails without KNOB_GATE"
printf 'OP_KNOB\nGONE_KNOB\n' > "${ALLOW}"
out="$(_knobs)"
t_assert_eq "1" "$(_rc)" "stale is a bookkeeping error, so it fails regardless of KNOB_GATE"
t_assert_contains "${out}" "STALE allow rows (1)"
t_assert_contains "${out}" "    GONE_KNOB"
t_assert_contains "${out}" "regardless of KNOB_GATE"

t_case "the same stale row fails under KNOB_GATE=1 too"
t_assert_eq "1" "$(_rc 1)"

t_case "an inline comment or padding on the row does not make it stale"
printf 'OP_KNOB   # documented operator switch\n' > "${ALLOW}"
t_assert_eq "0" "$(_rc 1)"

t_case "a row for a knob that is consumed AND owned elsewhere is redundant, not stale"
printf 'OP_KNOB\nPINNED_KNOB\n' > "${ALLOW}"
t_assert_eq "0" "$(_rc 1)"
t_assert_contains "$(_knobs)" "stale allow rows: 0"

t_case "an unowned knob stays advisory without KNOB_GATE and fails with it (unchanged)"
_consume PINNED_KNOB DOCKER_KNOB OP_KNOB LOOSE_KNOB > "${SUBJECT}"
printf 'OP_KNOB\n' > "${ALLOW}"
out="$(_knobs)"
t_assert_eq "0" "$(_rc)"
t_assert_contains "${out}" "UNOWNED knobs (1)"
t_assert_contains "${out}" "    LOOSE_KNOB"
t_assert_contains "${out}" "advisory"
t_assert_eq "1" "$(_rc 1)"

t_case "unowned plus stale without KNOB_GATE: stale still fails, and both lists print"
printf 'OP_KNOB\nGONE_KNOB\n' > "${ALLOW}"
out="$(_knobs)"
t_assert_eq "1" "$(_rc)"
t_assert_contains "${out}" "STALE allow rows (1)"
t_assert_contains "${out}" "UNOWNED knobs (1)"

t_case "a knob read only on a comment line is not a consumer -> its row is stale"
{ _consume PINNED_KNOB DOCKER_KNOB OP_KNOB
  printf '# vendored files reference ${%s:-} of their own\n' COMMENTED_KNOB; } > "${SUBJECT}"
printf 'OP_KNOB\nCOMMENTED_KNOB\n' > "${ALLOW}"
out="$(_knobs)"
t_assert_eq "1" "$(_rc 1)" "prose about a knob is not a reader of it"
t_assert_contains "${out}" "STALE allow rows (1)"
t_assert_contains "${out}" "    COMMENTED_KNOB"

t_case "a TRAILING comment is not a consumer, and \${#arr[@]} on that line still is"
{ _consume PINNED_KNOB DOCKER_KNOB
  printf 'a=(x); echo "${%s:-}${#a[@]}"   # superseded ${%s:-}\n' REAL_KNOB TRAILING_KNOB; } > "${SUBJECT}"
printf 'REAL_KNOB\nTRAILING_KNOB\n' > "${ALLOW}"
out="$(_knobs)"
t_assert_eq "1" "$(_rc 1)"
t_assert_contains "${out}" "STALE allow rows (1)" "REAL_KNOB is still consumed, only the comment is not"
t_assert_contains "${out}" "    TRAILING_KNOB"

t_case "the owner-census OK line is withheld while a stale row is failing"
t_assert_contains "${out}" "stale allow rows: 1"
t_assert_eq "0" "$(_knobs | grep -cF 'OK: every consumed knob has an owner')"

t_case "no allow file at all is not a stale condition"
rm -f "${ALLOW}"
_consume PINNED_KNOB DOCKER_KNOB > "${SUBJECT}"
t_assert_eq "0" "$(_rc 1)"

t_case "a real in-script assignment IS an owner"
{ _consume PINNED_KNOB DOCKER_KNOB SCRIPT_OWNED_KNOB
  printf '%s=1\n' SCRIPT_OWNED_KNOB; } > "${SUBJECT}"
: > "${ALLOW}"
t_assert_eq "0" "$(_rc 1)"

t_case "a knob owned only by a FULL-LINE comment is not owned"
{ _consume PINNED_KNOB DOCKER_KNOB COMMENT_OWNED_KNOB
  printf '# %s=1 is what operators set\n' COMMENT_OWNED_KNOB; } > "${SUBJECT}"
out="$(_knobs)"
t_assert_eq "1" "$(_rc 1)" "prose spelling NAME=value does not own the knob"
t_assert_contains "${out}" "UNOWNED knobs (1)"
t_assert_contains "${out}" "    COMMENT_OWNED_KNOB"

t_case "a knob owned only by a TRAILING comment is not owned either"
{ _consume PINNED_KNOB DOCKER_KNOB TRAILING_OWNED_KNOB
  printf 'true   # default when %s=1\n' TRAILING_OWNED_KNOB; } > "${SUBJECT}"
out="$(_knobs)"
t_assert_eq "1" "$(_rc 1)"
t_assert_contains "${out}" "    TRAILING_OWNED_KNOB"

t_case "a _-prefixed private is never a knob: the extraction regex needs [A-Z] first"
printf '#!/usr/bin/env bash\necho "${%s:-}${%s:-}"\n' PINNED_KNOB _PRIVATE_KNOB > "${SUBJECT}"
out="$(_knobs 1)"
t_assert_eq "0" "$(_rc 1)"
t_assert_contains "${out}" "OK: every consumed knob has an owner"
t_assert_eq "0" "$(printf '%s' "${out}" | grep -c 'PRIVATE_KNOB')"

t_case "a backslash-escaped \${KNOB:-} is literal output text, not a reader"
{ _consume PINNED_KNOB
  printf 'echo "the gate reads \\${%s:-x} in scripts"\n' ESCAPED_KNOB; } > "${SUBJECT}"
printf 'ESCAPED_KNOB\n' > "${ALLOW}"
out="$(_knobs)"
t_assert_eq "1" "$(_rc 1)" "an allow row for a name only printed literally is stale"
t_assert_contains "${out}" "STALE allow rows (1)"
t_assert_contains "${out}" "    ESCAPED_KNOB"

t_case "the REAL tree is clean today, under KNOB_GATE=1"
t_assert_eq "0" "$(t_rc env KNOB_GATE=1 bash "${LIVE}")"
t_assert_contains "$(KNOB_GATE=1 bash "${LIVE}" 2>&1)" "stale allow rows: 0"

t_summary
