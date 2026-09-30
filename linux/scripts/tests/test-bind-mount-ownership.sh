#!/usr/bin/env bash
# Tests for bind-mount-ownership.sh's selective chown and its root/non-root verdicts; chown, id and stat are stubbed.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SUBJECT="$(cd "${TESTS_DIR}/.." && pwd)/01-core/bind-mount-ownership.sh"

_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT

REAL_STAT="$(command -v stat)"
REAL_ID="$(command -v id)"

BIN="${_work}/bin"
mkdir -p "${BIN}"

cat > "${BIN}/chown" <<'STUB'
#!/usr/bin/env bash
printf 'chown %s\n' "$*" >> "${STUB_LOG}"
exit "${STUB_CHOWN_RC:-0}"
STUB

cat > "${BIN}/id" <<STUB
#!/usr/bin/env bash
if [ "\${1:-}" = "-u" ] && [ -n "\${STUB_UID:-}" ]; then printf '%s\\n' "\${STUB_UID}"; exit 0; fi
exec "${REAL_ID}" "\$@"
STUB

# STUB_STAT_UID/GID fake a bind mount's foreign owner; otherwise every path already matches.
cat > "${BIN}/stat" <<STUB
#!/usr/bin/env bash
if [ -n "\${STUB_STAT_UID:-}" ]; then
  case "\${2:-}" in
    "%u") printf '%s\\n' "\${STUB_STAT_UID}"; exit 0 ;;
    "%g") printf '%s\\n' "\${STUB_STAT_GID:-\${STUB_STAT_UID}}"; exit 0 ;;
  esac
fi
exec "${REAL_STAT}" "\$@"
STUB

chmod +x "${BIN}/chown" "${BIN}/id" "${BIN}/stat"

# A tree to hand back, and a reference path beside it.
TREE="${_work}/docs"
REF="${_work}"
mkdir -p "${TREE}/sub"
printf 'a\n' > "${TREE}/one.txt"
printf 'b\n' > "${TREE}/sub/two.txt"

OUT=""; rc=0; LOG=""
# _call <env-assignments...> -- <args to fix_bind_mount_ownership>
_call() {
  local -a env_pairs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do env_pairs+=("$1"); shift; done
  shift
  LOG="$(mktemp "${_work}/log.XXXXXX")"
  # Defaults spelled here give each stub switch an owner outside lint-env-knobs.allow.
  OUT="$(PATH="${BIN}:${PATH}" STUB_LOG="${LOG}" \
    STUB_CHOWN_RC=0 STUB_UID='' STUB_STAT_UID='' STUB_STAT_GID='' \
    env "${env_pairs[@]+"${env_pairs[@]}"}" \
    bash -c "$(t_stubbed_script "${SUBJECT}" fix_bind_mount_ownership "$@")" 2>&1)"
  rc=$?
}

t_case "a target that does not exist is not an error"
# A docs step that produced nothing must not have its finalize step break the lane.
_call -- "${_work}/never-written" "${REF}"
t_assert_eq "0" "${rc}" "output was: ${OUT}"
t_assert_contains "${OUT}" "Nothing to fix"
t_assert_eq "" "$(cat "${LOG}")" "nothing to fix means nothing to chown"

t_case "a tree already owned by the reference is a no-op, with NO chown at all"
# Selective, since a recursive chown of a correct tree fails for a non-owner.
_call -- "${TREE}" "${REF}"
t_assert_eq "0" "${rc}" "output was: ${OUT}"
t_assert_contains "${OUT}" "nothing to do"
t_assert_eq "" "$(cat "${LOG}")"

t_case "paths that differ are chowned to the REFERENCE's uid:gid"
_call STUB_STAT_UID=4242 STUB_STAT_GID=4343 -- "${TREE}" "${REF}"
t_assert_eq "0" "${rc}" "output was: ${OUT}"
t_assert_contains "$(cat "${LOG}")" "4242:4343"
t_assert_contains "${OUT}" "back to 4242:4343"

t_case "the chown names the paths, and is never a blanket -R over the target"
_chown="$(cat "${LOG}")"
t_assert_contains "${_chown}" "${TREE}/one.txt"
t_assert_contains "${_chown}" "${TREE}/sub/two.txt"
t_assert_eq "" "$(printf '%s' "${_chown}" | grep -F -- ' -R ' || true)" \
  "a blanket chown -R is the form this replaced"

t_case "chown is given -h, so a symlink is retargeted and not followed"
# Following a symlink could chown something outside the tree.
t_assert_contains "${_chown}" "chown -h "

t_case "the count in the log is the number of paths actually handed over"
_call STUB_STAT_UID=4242 -- "${TREE}" "${REF}"
t_assert_contains "${OUT}" "Handing 4 path(s)" \
  "docs/ plus one.txt plus sub/ plus sub/two.txt; a wrong count means the find and the chown disagree"

t_case "a failing chown as a NON-ROOT uid is explained, not a red nobody can act on"
_call STUB_STAT_UID=4242 STUB_CHOWN_RC=1 STUB_UID=1001 -- "${TREE}" "${REF}"
t_assert_eq "0" "${rc}" "only root can hand files to another uid; that is arithmetic, not a defect"
t_assert_contains "${OUT}" "not permitted for uid 1001"
t_assert_contains "${OUT}" "Only root can hand files to another uid"

t_case "the same failing chown AS ROOT is fatal"
_call STUB_STAT_UID=4242 STUB_CHOWN_RC=1 STUB_UID=0 -- "${TREE}" "${REF}"
t_assert_eq "1" "${rc}" "as root a chown failure is a read-only or broken mount, and the tree really is unusable"
t_assert_contains "${OUT}" "failed as root"

t_case "a missing reference path is fatal, and says which path"
_call -- "${TREE}" "${_work}/no-such-reference"
t_assert_eq "1" "${rc}"
t_assert_contains "${OUT}" "no-such-reference"

t_case "both arguments are required"
t_assert_fails bash -c "set -uo pipefail; source '${SUBJECT}'; fix_bind_mount_ownership"
t_assert_fails bash -c "set -uo pipefail; source '${SUBJECT}'; fix_bind_mount_ownership '${TREE}'"

t_summary
