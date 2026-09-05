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
mkdir -p "${_work}/linux/scripts/03-media/core" "${_work}/linux/scripts/04-runtime"
printf 'ARCH_FLAG_KNOB=1\n' > "${_work}/linux/scripts/03-media/core/arch-flags-riscv64.env"
printf 'PATHS_ENV_KNOB=/opt/x\n' > "${_work}/linux/scripts/04-runtime/runtime-paths.env"
printf 'FROM scratch\nARG DOCKER_KNOB\n' > "${_work}/linux/Dockerfile.subject"
# The copied gate reads its own ${KNOB_GATE:-0}; preflight.sh owns it in the real
# tree with `env KNOB_GATE=1 bash …`, so the fixture tree carries that caller too.
printf '#!/usr/bin/env bash\nenv KNOB_GATE=1 bash lint-env-knobs.sh\n' > "${_work}/linux/scripts/caller.sh"

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

t_case "a per-arch media flag file owns its knobs: media_load_arch_flags sources it"
_consume PINNED_KNOB DOCKER_KNOB OP_KNOB ARCH_FLAG_KNOB > "${SUBJECT}"
printf '# operator switch\nOP_KNOB\n' > "${ALLOW}"
t_assert_eq "0" "$(_rc 1)" "a knob whose VALUE is per-arch data needs no registry row"
t_assert_contains "$(_knobs)" "OK: every consumed knob has an owner"

t_case "runtime-paths.env is reference data for a checker, so it owns nothing"
_consume PINNED_KNOB DOCKER_KNOB OP_KNOB PATHS_ENV_KNOB > "${SUBJECT}"
out="$(_knobs)"
t_assert_eq "1" "$(_rc 1)" "no stage sources it; counting it would invent an owner"
t_assert_contains "${out}" "    PATHS_ENV_KNOB"

_consume PINNED_KNOB DOCKER_KNOB OP_KNOB > "${SUBJECT}"

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

# ── OWNERS: an assignment is code in command position, never text ────────────
# Every fixture below is passed as a single-quoted argument, so the live-tree
# census cannot see SHAPE_KNOB as an owner of its own suite.
: > "${ALLOW}"
_shape_rc() {
  { _consume PINNED_KNOB DOCKER_KNOB SHAPE_KNOB; printf '%s\n' "$@"; } > "${SUBJECT}"
  _rc 1
}

t_case "a knob owned only by an echo string is UNOWNED"
{ _consume PINNED_KNOB DOCKER_KNOB ECHOED_KNOB
  printf 'echo "out of disk; %s=1 accepts the risk" >&2\n' ECHOED_KNOB; } > "${SUBJECT}"
out="$(_knobs)"
t_assert_eq "1" "$(_rc 1)" "an operator switch mentioned only in a message has no owner"
t_assert_contains "${out}" "UNOWNED knobs (1)"
t_assert_contains "${out}" "    ECHOED_KNOB"

t_case "an assignment-shaped ARGUMENT is not an owner either"
{ _consume PINNED_KNOB DOCKER_KNOB ARGUMENT_KNOB
  printf '_helper %s=1\n' ARGUMENT_KNOB; } > "${SUBJECT}"
out="$(_knobs)"
t_assert_eq "1" "$(_rc 1)" "a word after the command name is an argument, not an assignment"
t_assert_contains "${out}" "    ARGUMENT_KNOB"

t_case "a reader to the right of a # INSIDE a quoted string is still a reader"
{ _consume PINNED_KNOB DOCKER_KNOB
  printf 'echo "tag: #${%s:-x}"\n' QUOTED_HASH_KNOB; } > "${SUBJECT}"
out="$(_knobs 1)"
t_assert_eq "1" "$(_rc 1)" "a flat cut at ` #` loses the reader and the gate goes quiet"
t_assert_contains "${out}" "    QUOTED_HASH_KNOB"

t_case "a real trailing comment after that same line is still stripped"
{ _consume PINNED_KNOB DOCKER_KNOB
  printf 'echo "tag: #x"   # ${%s:-x}\n' COMMENTED_TAIL_KNOB; } > "${SUBJECT}"
t_assert_eq "0" "$(_rc 1)" "the quote closed before the hash, so the tail is prose"

t_case "a comment that spells a whole assignment COMMAND is still only a comment"
{ _consume PINNED_KNOB DOCKER_KNOB COMMENTED_SHAPE_KNOB
  printf 'true   # set it with: export %s=1\n' COMMENTED_SHAPE_KNOB; } > "${SUBJECT}"
out="$(_knobs)"
t_assert_eq "1" "$(_rc 1)" "the keyword before it is inside the comment too"
t_assert_contains "${out}" "    COMMENTED_SHAPE_KNOB"

t_case "a NAME=value line inside a heredoc body is not an owner"
{ _consume PINNED_KNOB DOCKER_KNOB HEREDOC_KNOB
  printf 'cat > /tmp/x <<EOF\n%s=1\nEOF\n' HEREDOC_KNOB; } > "${SUBJECT}"
out="$(_knobs)"
t_assert_eq "1" "$(_rc 1)" "a heredoc body is emitted data, not this script's own assignment"
t_assert_contains "${out}" "    HEREDOC_KNOB"

t_case "a parameter expansion's own = is not an assignment"
t_assert_eq "1" "$(_shape_rc ': ${SHAPE_KNOB=x}')" "the documented self-defaulting form is : \"\${VAR:=…}\""
t_assert_eq "0" "$(_shape_rc ': "${SHAPE_KNOB:=x}"')" "…and that form still owns"

t_case "every assignment shape in command position owns"
t_assert_eq "0" "$(_shape_rc 'SHAPE_KNOB=1')"                        "a plain assignment"
t_assert_eq "0" "$(_shape_rc "SHAPE_KNOB=\${PINNED_KNOB:-x}")"       "a defaulted value"
t_assert_eq "0" "$(_shape_rc 'export SHAPE_KNOB=1')"                 "export"
t_assert_eq "0" "$(_shape_rc 'f() { local SHAPE_KNOB=1; }')"         "local, inside a function"
t_assert_eq "0" "$(_shape_rc 'readonly SHAPE_KNOB=1')"               "readonly"
t_assert_eq "0" "$(_shape_rc 'declare -x SHAPE_KNOB=1')"             "declare with a flag"
t_assert_eq "0" "$(_shape_rc 'SHAPE_KNOB=1 _helper')"                "an env prefix"
t_assert_eq "0" "$(_shape_rc '_other=0 SHAPE_KNOB=1 _helper')"       "the second of an env-prefix chain"
t_assert_eq "0" "$(_shape_rc 'FIRST=1 SECOND=2 SHAPE_KNOB=3 _helper')" "the third of a longer chain"
t_assert_eq "0" "$(_shape_rc 'true; SHAPE_KNOB=1')"                  "after ;"
t_assert_eq "0" "$(_shape_rc 'true && SHAPE_KNOB=1')"                "after &&"
t_assert_eq "0" "$(_shape_rc 'if true; then SHAPE_KNOB=1; fi')"      "after then"
t_assert_eq "0" "$(_shape_rc 'case "$1" in a) SHAPE_KNOB=1 ;; esac')" "in a case arm"
t_assert_eq "0" "$(_shape_rc '_v="$(SHAPE_KNOB=1 _helper)"')"        "inside \$( ) within a quoted word"

# ── HEREDOCS: the body is data in all four delimiter forms ───────────────────
# Each fixture pairs a body knob (must stay UNOWNED) with a real assignment
# AFTER the terminator (must still own), so a tokenizer that never terminates
# and swallows the rest of the file fails the case instead of passing it.
_t_hd() {
  local _what="$1"; shift
  { _consume PINNED_KNOB DOCKER_KNOB HD_BODY_KNOB SHAPE_KNOB
    printf '%s\n' "$@"; printf 'SHAPE_KNOB=1\n'; } > "${SUBJECT}"
  local _out; _out="$(_knobs 1)"
  t_assert_contains "${_out}" "UNOWNED knobs (1)" "${_what}: the assignment after the terminator still owns"
  t_assert_contains "${_out}" "    HD_BODY_KNOB" "${_what}: the body owns nothing"
}

t_case "a heredoc body is data whether or not the delimiter is quoted"
_t_hd "<<EOT"    'cat > /tmp/x <<EOT'    'HD_BODY_KNOB=1' 'EOT'
_t_hd "<<'EOT'"  "cat > /tmp/x <<'EOT'"  'HD_BODY_KNOB=1' 'EOT'
_t_hd '<<"EOT"'  'cat > /tmp/x <<"EOT"'  'HD_BODY_KNOB=1' 'EOT'
_t_hd '<<\EOT'   'cat > /tmp/x <<\EOT'   'HD_BODY_KNOB=1' 'EOT'

t_case "the <<- form strips tabs off the terminator it is looking for"
_t_hd '<<-EOT' 'cat <<-EOT' $'\tHD_BODY_KNOB=1' $'\tEOT'
_t_hd "<<-'EOT'" "cat <<-'EOT'" $'\tHD_BODY_KNOB=1' $'\tEOT'

t_case "two heredocs opened on ONE line are queued, not merged"
_t_hd 'two on one line' "cat <<'ONE' <<'TWO'" 'FIRST_BODY=1' 'ONE' 'HD_BODY_KNOB=2' 'TWO'

t_case "a heredoc opened inside \$( ) is still a heredoc"
_t_hd 'bare $( )'   "_v=\$(cat <<'SUBEOF'"      'HD_BODY_KNOB=1' 'SUBEOF' ')'
_t_hd 'quoted $( )' "_v=\"\$(cat <<'SUBEOF'\"" 'HD_BODY_KNOB=1' 'SUBEOF' ')"'

t_case "a here-string is not a heredoc: <<< swallows nothing"
_t_hd '<<<' 'grep -q x <<<"HD_BODY_KNOB=1"'

t_case "single-quoted text is not code either"
t_assert_eq "1" "$(_shape_rc "printf '%s\\n' \\" "  'SHAPE_KNOB=1 accepts the risk'")" \
  "a usage line continued onto its own line is a string, not an assignment"

t_case "an assignment-shaped ARGUMENT stays an argument after another argument"
t_assert_eq "1" "$(_shape_rc '_helper ONE_ARG=1 SHAPE_KNOB=2')" \
  "crediting it would make every word after an assignment-shaped argument an owner"

t_case "arithmetic is not a heredoc: << inside (( )) opens nothing"
_t_hd 'arith' '_shift=$(( 1 << 2 ))'

t_case "an unterminated heredoc does not eat the NEXT file"
# The scan is one awk over every script, so nhd must reset per file. Sorted file
# order puts this one first; without the reset it swallows subject.sh whole.
_eat="${_work}/linux/scripts/a-unterminated.sh"
printf '#!/usr/bin/env bash\ncat <<%s\nEATEN_KNOB=1\n' "'NEVERENDS'" > "${_eat}"
{ _consume PINNED_KNOB DOCKER_KNOB HD_BODY_KNOB SHAPE_KNOB; printf 'SHAPE_KNOB=1\n'; } > "${SUBJECT}"
_out="$(_knobs 1)"
t_assert_contains "${_out}" "UNOWNED knobs (1)" "the assignment in the next file still owns"
t_assert_contains "${_out}" "    HD_BODY_KNOB" "and the runaway body still owns nothing"
rm -f "${_eat}"

t_case "the 2026-09-04 build-window knobs default at their reader, not in a row"
_REPO="$(cd "${TESTS_DIR}/../../.." && pwd)"
for _k in IREE_CROSS_BUILD_COMPILER LINT_DOCKERFILES_BUILD_CHECK \
          LLVM_INSTALL_PROFILE MEDIA_STRIP NODE_RISCV64_MAJOR_REQUIRED OPENCV_GSTREAMER_PASS \
          PYTHON_LTO RUNTIME_CLANG_VERSION_SMOKE RUNTIME_COMPILER_SMOKE RUNTIME_IMAGE_SMOKE \
          SKIP_REAL_TREE STV_COMPUTE; do
  t_assert_ok grep -rqF -e ": \"\${${_k}:=" "${_REPO}/linux/scripts"
  t_assert_eq "" "$(grep -cE -e "^${_k}[[:space:]]*(#.*)?$" "${TESTS_DIR}/../lint-env-knobs.allow" \
    | sed 's/^0$//')" "${_k} owns its default at the reader; the registry row must be gone"
done

t_case "the REAL tree is clean today, under KNOB_GATE=1"
t_assert_eq "0" "$(t_rc env KNOB_GATE=1 bash "${LIVE}")"
t_assert_contains "$(KNOB_GATE=1 bash "${LIVE}" 2>&1)" "stale allow rows: 0"

t_summary
