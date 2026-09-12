#!/usr/bin/env bash
# Tests for linux/scripts/verify_consumer_inventory.py -- the gate that answers
# "who actually calls this hub", and so the gate a deletion decision rests on.
# It ran over five real repositories, and never over a tree whose answer was
# known in advance. These fixtures are that tree: four entry points, one per
# verdict, plus the two integrity rules the report's honesty rests on -- a
# consumer that cannot be obtained is a hard failure, never a skip, and a
# mention is not a call. Offline throughout (--offline plus --local for every
# consumer), so nothing here clones anything.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SCRIPTS="$(cd "${TESTS_DIR}/.." && pwd)"
GATE="${SCRIPTS}/verify_consumer_inventory.py"
PY="${PREFLIGHT_PYTHON:-python3}"

_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT

# A hub-shaped tree: one entry point per verdict the report can reach.
_hub() {
  local d
  d="$(mktemp -d "${_work}/hub.XXXXXX")"
  mkdir -p "${d}/linux/scripts"
  printf '#!/usr/bin/env bash\ntrue\n' > "${d}/linux/scripts/called-by-consumer.sh"
  printf '#!/usr/bin/env bash\ntrue\n' > "${d}/linux/scripts/hub-internal.sh"
  printf '#!/usr/bin/env bash\ntrue\n' > "${d}/linux/scripts/only-mentioned.sh"
  # It names its OWN path, in executable position: a file naming itself is not
  # a caller, so this must still come out as named by nobody.
  printf '#!/usr/bin/env bash\necho linux/scripts/nobody-names-it.sh\n' \
    > "${d}/linux/scripts/nobody-names-it.sh"
  # The hub's own use of one entry point, from a file that is not itself one.
  printf 'all:\n\tbash linux/scripts/hub-internal.sh\n' > "${d}/Makefile"
  git -C "${d}" init -q
  t_git_commit "${d}"
  printf '%s' "${d}"
}

# _consumer <shape> -- an external consumer checkout.
#   plain     one qualified call, one prose mention, nothing else
#   dangling  plus a qualified call to a hub path that does not exist
#   commented plus the same missing path, in a COMMENT
_consumer() {
  local d shape="$1"
  d="$(mktemp -d "${_work}/consumer.XXXXXX")"
  mkdir -p "${d}/scripts"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'bash third_party/ANTfrastructure/linux/scripts/called-by-consumer.sh\n'
    case "${shape}" in
      dangling)  printf 'bash third_party/ANTfrastructure/linux/scripts/gone.sh\n' ;;
      commented) printf '# third_party/ANTfrastructure/linux/scripts/gone.sh was removed upstream\n' ;;
    esac
  } > "${d}/scripts/build.sh"
  printf 'We use third_party/ANTfrastructure/linux/scripts/only-mentioned.sh one day.\n' \
    > "${d}/README.md"
  git -C "${d}" init -q
  t_git_commit "${d}"
  printf '%s' "${d}"
}

# _inventory <file> <classes-json> [self-flag-for-the-hub]
_inventory() {
  local out="$1" classes="$2" self="${3:-true}"
  cat > "${out}" <<JSON
{
  "hub": { "owner": "Kataglyphis", "repo": "ANTfrastructure",
           "submodule_path": "third_party/ANTfrastructure" },
  "consumers": [
    { "name": "hub-self", "clone_url": "unused", "ref": "main", "self": ${self} },
    { "name": "consumer-a", "clone_url": "unused", "ref": "main", "self": false }
  ],
  "entry_point_classes": ${classes}
}
JSON
}

_CLASSES='[ { "kind": "linux-script", "glob": "linux/scripts/*.sh", "needle": "path" } ]'
_CLASSES_EMPTY='[ { "kind": "linux-script", "glob": "linux/scripts/*.sh", "needle": "path" },
                  { "kind": "nothing-here", "glob": "no/such/dir/*.sh", "needle": "path" } ]'

REPORT=""
OUT=""; rc=0
# _run <hub> <consumer> <inventory> [extra args...]
_run() {
  local hub="$1" consumer="$2" inv="$3"
  shift 3
  REPORT="$(mktemp "${_work}/report.XXXXXX")"
  OUT="$("${PY}" "${GATE}" --inventory "${inv}" --hub-root "${hub}" --offline \
    --local "hub-self=${hub}" --local "consumer-a=${consumer}" \
    --report "${REPORT}" "$@" 2>&1)"
  rc=$?
}

# The rows of one report section, which is where the verdict lives: the same
# entry point appears in every report, only under a different heading.
_section() { sed -n "/^## $1 --/,/^## .* --/p" "${REPORT}"; }

if ! command -v "${PY}" >/dev/null 2>&1 || ! "${PY}" -c pass >/dev/null 2>&1; then
  t_case "python is unavailable"
  t_assert_eq "no-python" "no-python" "PREFLIGHT_PYTHON unset and python3 is a stub"
  t_summary
  exit 0
fi

_h="$(_hub)"
_c="$(_consumer plain)"
_inv="${_work}/inventory.json"
_inventory "${_inv}" "${_CLASSES}"

t_case "a tree whose answer is known in advance grades every entry point right"
_run "${_h}" "${_c}" "${_inv}"
t_assert_eq "0" "${rc}" "the fixture has no dangling reference; output was: ${OUT}"

t_assert_contains "$(_section 'Reached by a consumer')" "linux/scripts/called-by-consumer.sh" \
  "a qualified call from an external repo is what 'load-bearing outside this repo' means"
t_assert_contains "$(_section 'Reached by a consumer')" 'consumer-a (`scripts/build.sh:2`)' \
  "the verdict must carry the evidence; a status with no witness cannot be checked"

t_assert_contains "$(_section 'Hub-internal only')" "linux/scripts/hub-internal.sh" \
  "reached only from the hub is NOT a consumer -- that distinction is the whole report"
t_assert_eq "" "$(_section 'Reached by a consumer' | grep -F 'hub-internal.sh' || true)"

t_assert_contains "$(_section 'Mentioned, never reached')" "linux/scripts/only-mentioned.sh" \
  "a name in a README keeps nothing alive; prose must not read as a call"

t_assert_contains "$(_section 'Named by nobody')" "linux/scripts/nobody-names-it.sh" \
  "the only hit on it is its own file naming itself, which is not a caller"

t_case "an executable reference to a hub path that does not exist FAILS the run"
_run "${_h}" "$(_consumer dangling)" "${_inv}"
t_assert_eq "1" "${rc}" "a caller pointing at nothing is the other half of this question"
t_assert_contains "${OUT}" "names a hub path that does not exist"
t_assert_contains "${OUT}" "linux/scripts/gone.sh"

t_case "the same missing path in a COMMENT is prose, not a broken call"
_run "${_h}" "$(_consumer commented)" "${_inv}"
t_assert_eq "0" "${rc}" \
  "a comment recording that a path was removed must not fail the run; output was: ${OUT}"

t_case "an entry point class that expands to NOTHING is refused"
_inventory "${_work}/empty-class.json" "${_CLASSES_EMPTY}"
_run "${_h}" "${_c}" "${_work}/empty-class.json"
t_assert_eq "1" "${rc}" "a class matching nothing silently narrows the report to less than it claims"
t_assert_contains "${OUT}" "matches nothing"

t_case "an inventory with no self:true consumer is refused"
_inventory "${_work}/no-self.json" "${_CLASSES}" false
_run "${_h}" "${_c}" "${_work}/no-self.json"
t_assert_eq "1" "${rc}" "without the hub marked self, hub-internal use reads as an external caller"
t_assert_contains "${OUT}" "no consumer is marked self:true"

t_case "a consumer that cannot be obtained is a hard failure, never a skip"
OUT="$("${PY}" "${GATE}" --inventory "${_inv}" --hub-root "${_h}" --offline \
  --local "hub-self=${_h}" 2>&1)"; rc=$?
t_assert_eq "1" "${rc}" "skipping it would turn 'no caller found' into a lie with the same shape as the truth"
t_assert_contains "${OUT}" "Skipping it would make the inventory lie"

t_summary
