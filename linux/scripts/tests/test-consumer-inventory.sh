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
  # One real PowerShell module, so a module-name reference has something to
  # resolve against: without it EVERY Windows* name would dangle and the
  # module case below would pass for the wrong reason.
  mkdir -p "${d}/windows/scripts/modules"
  printf '%s\n' 'function Get-Thing { }' > "${d}/windows/scripts/modules/WindowsBuild.Common.psm1"
  # The hub's own use of one entry point, from a file that is not itself one.
  printf 'all:\n\tbash linux/scripts/hub-internal.sh\n' > "${d}/Makefile"
  git -C "${d}" init -q
  t_git_commit "${d}"
  printf '%s' "${d}"
}

# _consumer <shape> -- an external consumer checkout.
#   plain      one qualified call, one prose mention, nothing else
#   dangling   plus a qualified call to a hub path that does not exist
#   commented  plus the same missing path, in a COMMENT
#   backslash  plus a PowerShell call spelling a missing hub path with
#              BACKSLASHES, which is how half the fleet writes hub paths and
#              which a slash-only qualifier could not see at all
#   escape     plus a shell line that PRINTS an existing hub path, from a
#              format string ending in the two characters a C escape is
#              spelled with -- which are not a path separator
#   fixture    a consumer-layout TEST tree naming a missing hub path with
#              backslashes; a fixture path that must not exist is the fixture
#              doing its job, in any repo's directory naming
#   module     plus the three shapes that reach a module by NAME rather than
#              by path -- Import-BuildModule, Resolve-BuildModule -Name, and a
#              Join-Path onto '<Name>.psm1'. A path-only scan can never see one
#              of these dangle, and a dangling module name fails at RUNTIME,
#              inside a build, with "module not found".
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
      escape)    printf '%s\n' "printf '  third_party/ANTfrastructure/linux/scripts/called-by-consumer.sh\\n'" ;;
    esac
  } > "${d}/scripts/build.sh"
  case "${shape}" in
    backslash)
      printf '%s\n' '& "third_party\ANTfrastructure\linux\scripts\gone.ps1"' > "${d}/scripts/Build-Windows.ps1" ;;
    fixture)
      mkdir -p "${d}/scripts/windows/tests"
      printf '%s\n' \
        "Should Match ([regex]::Escape('third_party\\ANTfrastructure\\windows\\scripts\\modules\\NoSuchModule.psm1'))" \
        > "${d}/scripts/windows/tests/Resolve-BuildModule.Tests.ps1" ;;
    module)
      { printf '%s\n' "Import-BuildModule @('WindowsBuild.Common', 'WindowsGone.Common')"
        printf '%s\n' "Resolve-BuildModule -Name 'WindowsAlsoGone.Common'"
        printf '%s\n' "Import-Module (Join-Path \$modulesDir 'WindowsThirdGone.Common.psm1')"
      } > "${d}/scripts/Build-Windows.ps1" ;;
  esac
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

# _clean <shape> <needle> <why> -- a consumer the gate must find NOTHING in.
# Both callers below assert the same two things about a different false
# positive, so the block has one owner rather than a twin.
_clean() {
  local shape="$1" needle="$2" why="$3" c
  c="$(_consumer "${shape}")"
  _run "${_h}" "${c}" "${_inv}"
  t_assert_eq "0" "${rc}" "${why}; output was: ${OUT}"
  t_assert_eq "" "$(printf '%s' "${OUT}" | grep -F "${needle}" || true)" \
    "the gate reported ${needle}, which is not a broken call"
  rm -rf "${c}"
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

t_case "a BACKSLASH-spelled hub path is a hub path"
# Half the fleet writes hub paths with backslashes, and a slash-only qualifier
# matched none of them -- so every Windows-side reference was invisible here,
# which is the half of the fleet where three files were deleted for "no callers".
_cb="$(_consumer backslash)"
_run "${_h}" "${_cb}" "${_inv}"
t_assert_eq "1" "${rc}" "a dangling backslash path must fail the run like any other"
t_assert_contains "${OUT}" "gone.ps1" "the finding must name the path it could not resolve"
rm -rf "${_cb}"

t_case "a printed hub path is a path, and the escape after it is not a segment"
# ref_re carries the backslash so a Windows-spelled path is visible at all --
# and that made a printf format's trailing escape read as one more segment: the
# gate invented `shared-assets.manifest` + `/n` and reported a file that is
# right there as a dangling reference, on the hub's own run-lint-gates.sh. A
# reference spelled with slashes ENDS at the first backslash.
_clean escape 'called-by-consumer.sh/n' \
  "the printed path exists; only the C escape after it is new"

t_case "a consumer's TEST tree is a fixture tree, whatever the layout calls it"
# The hub writes linux/scripts/tests/, a consumer writes scripts/windows/tests/,
# and both build fake trees naming paths that must NOT exist. A negative test
# asserting that resolving 'NoSuchModule' names the locations it searched is
# the fixture doing its job; reading it as a broken call is how the two hub
# prefixes failed the whole fleet the moment backslashes became visible.
_clean fixture 'NoSuchModule' \
  "a fixture path in a consumer's test tree must not fail the run"

t_case "a module reached by NAME can dangle, in all three shapes"
# A PowerShell module is asked for by name, never by path, so a path-only scan
# can never see one dangle -- and a dangling name fails at RUNTIME, inside a
# build, with "module not found".
_cm="$(_consumer module)"
_run "${_h}" "${_cm}" "${_inv}"
t_assert_eq "1" "${rc}" "three missing modules must fail the run"
for _shape in WindowsGone.Common WindowsAlsoGone.Common WindowsThirdGone.Common; do
  t_assert_contains "${OUT}" "${_shape}" "the ${_shape} reference shape is not graded"
done
t_assert_eq "" "$(printf '%s' "${OUT}" | grep -F 'WindowsBuild.Common' || true)" \
  "a module the hub DOES ship must not be reported; that would make the check noise"
rm -rf "${_cm}"

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
