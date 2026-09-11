#!/usr/bin/env bash
# Tests for lint-workflows.sh. Its own header names the hazard: "a lint gate that
# checks nothing still reports green". Two ways that happens here -- linting the
# WRONG tree (the consumer-root argument exists because a submodule checkout puts
# this script inside the consumer), and running an UNPINNED binary. Both are
# driven against the real actionlint, plus the refusals that keep the pin honest.
# docs/code-quality-tooling.md#workflow-lint-workflow-lint
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SCRIPTS="${TESTS_DIR}/.."
GATE="${SCRIPTS}/lint-workflows.sh"
PIN="$(sed -n 's/^ACTIONLINT_VERSION=//p' "${SCRIPTS}/01-core/versions.env")"

CONV="${SCRIPTS}/verify_workflow_conventions.py"
HUB_ALLOW="${SCRIPTS}/workflow-conventions.allow"
HUB_CONSUMERS="${SCRIPTS}/../../.github/consumers.json"
# The same interpreter contract lint-workflows.sh documents: plain python3 is a
# Microsoft Store stub on a Windows host, so honour PREFLIGHT_PYTHON.
_PY="${PREFLIGHT_PYTHON:-python3}"
# preflight.sh ARMS the conventions gate for its own run. A suite that inherited
# that value would call the ramped checks fatal in the cases below that exist to
# prove they are not, and the ramp would look driven while nothing drove it.
unset WORKFLOW_CONVENTIONS_GATE

_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT

# _conv_half <tree> <allow body>: the conventions half of the gate, at the depth
# it resolves its own allow file and consumers.json from. Every fake hub tree
# below needs it, because lint-workflows.sh now runs two Python gates and a
# missing one is a failure, not a skip.
_conv_half() {
  install -D -m 0644 "${CONV}" "$1/linux/scripts/verify_workflow_conventions.py"
  install -D -m 0644 "${HUB_CONSUMERS}" "$1/.github/consumers.json"
  printf '%s\n' "$2" > "$1/linux/scripts/workflow-conventions.allow"
}

# _root <clean|broken|shellonly>: a consumer checkout with one workflow of that
# shape. `shellonly` carries a defect NOTHING but the embedded shellcheck pass
# of actionlint can see: SC1010, `[ ... ] then` with no separator. The YAML is
# valid, the expressions are valid, the step is valid -- so a green verdict on
# this fixture means the shell half of the gate did not run.

# ubuntu-24.04, not ubuntu-latest: the `*-latest` ban is ENFORCED now and would
# make every case above red for a reason none of them is about. Not
# ubuntu-26.04 either: these fixtures carry no .github/actionlint.yaml, so the
# preview label would fail actionlint's own runner-label rule instead. The
# `permissions:` and `timeout-minutes:` are there for the same reason -- these
# cases are about actionlint -- and the `origin` remote names a repository
# consumers.json declares, because the conventions half refuses a tree whose
# name no allow row could ever be keyed to.
_root() {
  local d; d="$(mktemp -d "${_work}/root.XXXXXX")"
  mkdir -p "${d}/.github/workflows"
  git -C "${d}" init -q   # actionlint resolves a project from the enclosing repo
  git -C "${d}" remote add origin "https://github.com/Kataglyphis/OxidANT.git"
  {
    printf 'name: ci\non: push\npermissions:\n  contents: read\njobs:\n  build:\n'
    printf '    runs-on: ubuntu-24.04\n    timeout-minutes: 5\n    steps:\n'
    case "$1" in
      broken)    printf '      - run: echo "${{ github.no_such_property }}"\n' ;;
      shellonly) printf '      - run: |\n          if [ "x" = "y" ] then\n            echo hi\n          fi\n' ;;
      *)         printf '      - run: echo hello\n' ;;
    esac
  } > "${d}/.github/workflows/ci.yml"
  printf '%s' "${d}"
}

t_case "a clean consumer checkout passes, and says which tree it linted"
clean="$(_root clean)"
_out="$(t_out bash "${GATE}" "${clean}")"
t_assert_eq "0" "$(t_rc bash "${GATE}" "${clean}")" \
  "the gate must be able to be green, or the red below proves only that it is broken"
t_assert_contains "${_out}" "linting workflows under ${clean}"
t_assert_contains "${_out}" "WORKFLOW LINT OK"

t_case "a real actionlint finding FAILS the gate"
broken="$(_root broken)"
_out="$(t_out bash "${GATE}" "${broken}")"
t_assert_eq "1" "$(t_rc bash "${GATE}" "${broken}")" "printing findings and exiting 0 is the whole hazard"
t_assert_contains "${_out}" "WORKFLOW LINT FAILED"
t_assert_contains "${_out}" "no_such_property" "the finding itself has to reach the log to be actionable"

t_case "the root argument decides WHICH tree is linted"
# A submodule checkout puts this script inside the consumer, where the default
# root resolves to ContainerHub. The two verdicts must follow the ARGUMENT: the
# broken checkout red, a clean sibling green while the broken one still exists.
t_assert_eq "1" "$(t_rc bash "${GATE}" "${broken}")"
t_assert_eq "0" "$(t_rc bash "${GATE}" "${clean}")" \
  "a gate that ignored its argument would give both checkouts the same verdict"
t_assert_contains "$(t_out bash "${GATE}" "${broken}")" "linting workflows under ${broken}" \
  "the banner must name the root it was handed"

t_case "a root that does not exist refuses, it does not fall back to this repo"
t_assert_eq "1" "$(t_rc bash "${GATE}" "${_work}/no-such-checkout")" \
  "falling back would lint a clean tree and report OK for a checkout nobody looked at"

t_case "the actionlint it runs is the pinned version"
t_assert_contains "$(t_out bash "${GATE}" "${clean}")" "actionlint (${PIN})" \
  "a lint verdict nobody can reproduce is not a gate"

# --- the bootstrap refusals: an unpinned binary must never run ----------------
# The gate resolves its pin from the versions.env beside ITSELF, so a throwaway
# copy at the real depth is what lets these be driven without a network.

# _stage <fixture root> <path under linux/scripts/> [mode] -- put one of this
# repo's files into a fixture at the SAME relative path. "The real depth" is the
# whole point of these trees (the gate resolves its pin from the versions.env
# beside itself), so the destination is never spelled out separately from the
# source: two functions below stage files, and writing the pair twice is how
# they would drift apart.
_stage() {
  install -D -m "${3:-0644}" "${SCRIPTS}/$2" "$1/linux/scripts/$2"
}

_pin_tree() {  # <versions.env body>
  local d; d="$(mktemp -d "${_work}/pin.XXXXXX")"
  _stage "${d}" lint-workflows.sh 0755
  _stage "${d}" 01-core/load-versions-env.sh
  _stage "${d}" 01-core/downloads.sh
  printf '%s\n' "$1" > "${d}/linux/scripts/01-core/versions.env"
  mkdir -p "${d}/.github/workflows"
  git -C "${d}" init -q
  git -C "${d}" remote add origin "https://github.com/Kataglyphis/OxidANT.git"
  printf '%s' "${d}"
}

# A PATH with no actionlint on it and an empty cache dir, so the bootstrap is forced.
_no_tool() {
  local d="$1"
  PATH="/usr/bin:/bin" ACTIONLINT_CACHE_DIR="${_work}/empty-cache" \
    bash "${d}/linux/scripts/lint-workflows.sh" "${d}"
}

t_case "no ACTIONLINT_VERSION: the gate errors instead of linting with whatever it finds"
d="$(_pin_tree 'SOMETHING_ELSE=1')"
t_assert_eq "1" "$(t_rc _no_tool "${d}")"
t_assert_contains "$(t_out _no_tool "${d}")" "ACTIONLINT_VERSION is not set"

t_case "a pinned version with no pinned SHA256 is refused"
# Downloading a release nobody checksummed is how a lint gate starts running a
# binary the repo never chose.
d="$(_pin_tree "ACTIONLINT_VERSION=${PIN}")"
t_assert_eq "1" "$(t_rc _no_tool "${d}")"
t_assert_contains "$(t_out _no_tool "${d}")" "No pinned actionlint SHA256"

# --- the SHELL half of the gate ----------------------------------------------
# actionlint embeds a shellcheck pass over every `run:` block and reaches it by
# exec'ing the command name. With that name absent it DISABLES the rule and says
# nothing at normal verbosity -- so the gate printed WORKFLOW LINT OK over
# workflows whose shell nothing had read. These cases are the two halves of the
# fix: the rule is on, and a gate that cannot switch it on refuses to grade.

t_case "a run: block defect only shellcheck can see FAILS the gate"
shellonly="$(_root shellonly)"
_out="$(t_out bash "${GATE}" "${shellonly}")"
t_assert_eq "1" "$(t_rc bash "${GATE}" "${shellonly}")" \
  "the YAML is valid and the expressions are valid: a green verdict here means no run: block was read as shell"
t_assert_contains "${_out}" "shellcheck reported issue" \
  "the finding has to reach the log, not just the exit code"
t_assert_contains "${_out}" "SC1010"

t_case "the gate names the shellcheck it resolved, so the resolution is not a claim"
t_assert_contains "$(t_out bash "${GATE}" "${clean}")" "shellcheck for run: blocks ("

# A tree at the real depth again, this time varying the ACCESSOR the gate
# resolves shellcheck through. Nothing else can drive "shellcheck could not be
# resolved" without unpinning the host that runs this suite. The real pins and
# the CI-image-ref half are copied in so a refusal below is about shellcheck and
# nothing else.
_sc_tree() {  # <lint-shell.sh body>
  local d; d="$(_pin_tree "$(cat "${SCRIPTS}/01-core/versions.env")")"
  install -D -m 0644 "${SCRIPTS}/verify_ci_image_refs.py" \
    "${d}/linux/scripts/verify_ci_image_refs.py"
  # gate_scope.py too: verify_ci_image_refs.py imports it, and a fixture that
  # does not carry what the gate NEEDS fails with a traceback, not a verdict.
  install -D -m 0644 "${SCRIPTS}/gate_scope.py" "${d}/linux/scripts/gate_scope.py"
  _conv_half "${d}" "$(cat "${HUB_ALLOW}")"
  printf '#!/usr/bin/env bash\n%s\n' "$1" > "${d}/linux/scripts/lint-shell.sh"
  chmod +x "${d}/linux/scripts/lint-shell.sh"
  printf 'name: ci\non: push\npermissions:\n  contents: read\njobs:\n  build:\n    runs-on: ubuntu-24.04\n    timeout-minutes: 5\n    steps:\n      - run: echo hello\n' \
    > "${d}/.github/workflows/ci.yml"
  printf '%s' "${d}"
}
_sc_run() { bash "$1/linux/scripts/lint-workflows.sh" "$1"; }

t_case "the fixture itself is sound: with the REAL accessor this tree lints green"
# Without this the two refusals below could both be passing for the wrong reason
# (a broken fixture), which is the shape this repo keeps finding.
d="$(_sc_tree "exec bash '${SCRIPTS}/lint-shell.sh' \"\$@\"")"
t_assert_contains "$(t_out _sc_run "${d}")" "shellcheck for run: blocks ("
t_assert_eq "0" "$(t_rc _sc_run "${d}")" \
  "actionlint runs, shellcheck resolves, and the CI-image-ref half is satisfied"

t_case "shellcheck that cannot be resolved FAILS the gate, it does not lint half a gate"
d="$(_sc_tree 'exit 1')"
t_assert_eq "1" "$(t_rc _sc_run "${d}")" \
  "linting workflows with the shellcheck rule off is the defect, not a degraded mode"
t_assert_contains "$(t_out _sc_run "${d}")" "shellcheck could not be resolved"

t_case "a resolved binary that reports nothing also fails: the rule must actually FIRE"
# --print-bin answers with a real, correctly NAMED, executable shellcheck that
# happens to find nothing -- the shape of every way the rule can be present and
# useless (a stub on PATH, an unusable build, a platform where actionlint's own
# name lookup misses the file bash just found). Every precondition passes here;
# only the planted-SC1010 self-test can tell it from a working gate.
_fake="${_work}/fake-sc"
mkdir -p "${_fake}"
printf '#!/usr/bin/env bash\nexit 0\n' > "${_fake}/shellcheck"
chmod +x "${_fake}/shellcheck"
d="$(_sc_tree "echo '${_fake}/shellcheck'")"
# System tools only, so the ACCESSOR's answer is the only shellcheck in play:
# CI's runner carries one on PATH, and it would answer actionlint's name lookup
# behind the stub and make this case pass while proving nothing.
_sc_run_isolated() { PATH="/usr/bin:/bin" bash "$1/linux/scripts/lint-workflows.sh" "$1"; }
t_assert_eq "1" "$(t_rc _sc_run_isolated "${d}")" \
  "the gate must not report a verdict it could not have reached"
_out="$(t_out _sc_run_isolated "${d}")"
t_assert_contains "${_out}" "did not report the planted SC1010"
# The precondition is satisfied here on purpose: a refusal from the NAME check
# instead would leave the self-test unproven, and the mutation gate said so.
t_assert_fails grep -q -F -e 'does not resolve on PATH' <<<"${_out}"

# --- the four fleet conventions ----------------------------------------------
# Four rules the fleet transmitted as copied header comments and enforced
# nowhere. The `*-latest` ban is enforced from day one because the fleet is
# measured clean of it; the other three carry a real backlog, so they REPORT and
# pass until WORKFLOW_CONVENTIONS_GATE arms them. Both halves of that ramp are
# driven here, because "advisory" that cannot become fatal is just a comment
# with a longer path.

# _conv_root <name> <body>: a consumer checkout whose `origin` names a
# repository .github/consumers.json declares, which is how the gate keys the
# allow file's rows. Without a remote it would fall back to the mktemp
# directory name and no row could ever match.
_conv_root() {
  local d; d="$(mktemp -d "${_work}/conv.XXXXXX")"
  mkdir -p "${d}/.github/workflows"
  git -C "${d}" init -q
  git -C "${d}" remote add origin "https://github.com/Kataglyphis/$1.git"
  printf '%s\n' "$2" > "${d}/.github/workflows/ci.yml"
  printf '%s' "${d}"
}

# A workflow that keeps all four conventions, so a red below is about the one
# thing the case changed.
_CONV_CLEAN='name: ci
on: push
permissions:
  contents: read
jobs:
  build:
    runs-on: ubuntu-24.04
    timeout-minutes: 15
    steps:
      - uses: actions/upload-artifact@v7
        with:
          name: out
          path: dist
          if-no-files-found: error'

# The same workflow with all three ramped conventions broken and nothing else.
_CONV_RAMPED='name: ci
on: push
jobs:
  build:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/upload-artifact@v7
        with:
          name: out
          path: dist'

_conv() { "${_PY}" "${CONV}" "$1"; }

t_case "the conventions half runs as part of lint-workflows.sh, not beside it"
# The wiring is the point: a gate nobody calls asserts nothing.
t_assert_contains "$(t_out bash "${GATE}" "${clean}")" "workflow conventions under ${clean}" \
  "the shell gate must name the tree it handed to the conventions half"

t_case "a clean workflow satisfies all four conventions"
d="$(_conv_root OxidANT "${_CONV_CLEAN}")"
t_assert_eq "0" "$(t_rc _conv "${d}")" \
  "the gate must be able to be green, or every red below proves only that it is broken"
t_assert_contains "$(t_out _conv "${d}")" "WORKFLOW CONVENTIONS OK (OxidANT)"

t_case "a *-latest runner label FAILS with no knob, in seven headers' place"
d="$(_conv_root OxidANT "${_CONV_CLEAN//ubuntu-24.04/ubuntu-latest}")"
t_assert_eq "1" "$(t_rc _conv "${d}")" \
  "the ban is measured clean fleet-wide, so it is enforced rather than restated"
t_assert_contains "$(t_out _conv "${d}")" "[runner-ban] runner label 'ubuntu-latest'"

t_case "a *-latest label reached through a matrix column is caught too"
# `runs-on: \${{ matrix.runs_on }}` puts the banned alias two lines away from
# the key a grep for `runs-on:.*-latest` would look at.
d="$(_conv_root OxidANT 'name: ci
on: push
permissions:
  contents: read
jobs:
  build:
    strategy:
      matrix:
        include:
          - runs_on: windows-latest
    runs-on: ${{ matrix.runs_on }}
    timeout-minutes: 15
    steps:
      - run: echo hi')"
t_assert_eq "1" "$(t_rc _conv "${d}")"
t_assert_contains "$(t_out _conv "${d}")" "runner label 'windows-latest'"

t_case "the three ramped conventions REPORT and pass while unarmed"
ramped="$(_conv_root OxidANT "${_CONV_RAMPED}")"
_out="$(t_out _conv "${ramped}")"
t_assert_eq "0" "$(t_rc _conv "${ramped}")" \
  "turning eight repositories red in one commit is what the ramp exists to avoid"
t_assert_contains "${_out}" "ADVISORY .github/workflows/ci.yml:4 [job-timeout]"
t_assert_contains "${_out}" "[permissions] no top-level"
t_assert_contains "${_out}" "[artifact-error] upload-artifact step"
t_assert_contains "${_out}" "set WORKFLOW_CONVENTIONS_GATE=" \
  "an advisory that does not say how to arm it is a comment with a longer path"

t_case "...and FAIL once armed, which is the half that makes the ramp a ramp"
_armed() { WORKFLOW_CONVENTIONS_GATE=1 "${_PY}" "${CONV}" "$1"; }
t_assert_eq "1" "$(t_rc _armed "${ramped}")"
_out="$(t_out _armed "${ramped}")"
t_assert_contains "${_out}" "FAIL: .github/workflows/ci.yml:4 [job-timeout]"
t_assert_contains "${_out}" "WORKFLOW CONVENTION GATE FAILED (3 finding(s)"

t_case "arming one check leaves the other two advisory"
_one() { WORKFLOW_CONVENTIONS_GATE=permissions "${_PY}" "${CONV}" "$1"; }
t_assert_eq "1" "$(t_rc _one "${ramped}")"
t_assert_contains "$(t_out _one "${ramped}")" "WORKFLOW CONVENTION GATE FAILED (1 finding(s)" \
  "a per-check knob is how a convention gets cleared one repository at a time"

t_case "a WORKFLOW_CONVENTIONS_GATE nobody can spell is refused, not ignored"
_typo() { WORKFLOW_CONVENTIONS_GATE=job-timeouts "${_PY}" "${CONV}" "$1"; }
t_assert_eq "1" "$(t_rc _typo "${ramped}")" \
  "silently arming nothing is how a gate reports green over a convention nobody enforced"
t_assert_contains "$(t_out _typo "${ramped}")" "names unknown check(s): job-timeouts"

t_case "a job that CALLS a reusable workflow is not asked for timeout-minutes"
# GitHub rejects the key on such a job outright, so demanding it would make the
# only fix an invalid workflow.
d="$(_conv_root OxidANT 'name: ci
on: push
permissions:
  contents: read
jobs:
  call:
    uses: ./.github/workflows/other.yml')"
t_assert_eq "0" "$(t_rc _conv "${d}")"
# The FINDING text, not the bare check name: the banner and the census ratchet
# both name every check, armed or not, so `[job-timeout]` alone matches a line
# that says nothing about this job.
t_assert_fails grep -q -F -e "[job-timeout] job 'call'" <<<"$(t_out _conv "${d}")"

# --- the EXCUSED-with-reason table -------------------------------------------
# A deviation is declared, never silent; and the declaration is graded too, so
# the list can only shrink by becoming true.

# _conv_hub <allow body> -> a hub tree carrying that allow file, the real
# consumers.json, and the gate at the depth it resolves both from.
_conv_hub() {
  local d; d="$(mktemp -d "${_work}/convhub.XXXXXX")"
  _conv_half "${d}" "$1"
  printf '%s' "${d}"
}
_conv_at() { "${_PY}" "$1/linux/scripts/verify_workflow_conventions.py" "$2"; }

_ROW='OxidANT | .github/workflows/ci.yml | job-timeout | build | measured at 4 minutes and bounded upstream; a timeout here would only fire on an outage'

# One deviation and nothing else, so an excuse that works turns the tree green
# under FULL arming - which is the only way to see that it silenced the finding
# rather than that some other finding was missing.
one_off="$(_conv_root OxidANT 'name: ci
on: push
permissions:
  contents: read
jobs:
  build:
    runs-on: ubuntu-24.04
    steps:
      - run: echo hi')"

t_case "a declared deviation is excused, and its REASON reaches the log"
hub="$(_conv_hub "${_ROW}")"
_excused() { WORKFLOW_CONVENTIONS_GATE=1 _conv_at "${hub}" "${one_off}"; }
t_assert_eq "1" "$(t_rc _armed "${one_off}")" \
  "unexcused, this tree is red under arming: otherwise the case below proves nothing"
t_assert_eq "0" "$(t_rc _excused)" \
  "an excused finding may not fail even when its check is armed"
_out="$(t_out _excused)"
t_assert_contains "${_out}" "EXCUSED .github/workflows/ci.yml:6 [job-timeout] measured at 4 minutes"

t_case "a row that matches nothing is STALE and fails whatever the arming says"
# The arming knob ramps the FINDINGS; the bookkeeping half never ramps, or the
# table rots into a list of things that used to be true.
clean_root="$(_conv_root OxidANT "${_CONV_CLEAN}")"
_stale() { _conv_at "${hub}" "${clean_root}"; }
t_assert_eq "1" "$(t_rc _stale)" \
  "unarmed is exactly when a stale row would otherwise sit unnoticed"
t_assert_contains "$(t_out _stale)" "STALE allow row"

t_case "a row for ANOTHER repository is neither used nor stale here"
# One table is shared by every consumer through the submodule, so a row about
# BeschleunigerBallett must not turn OxidANT red - and must not be reported
# resolved either, because this tree cannot see the file it names.
hub2="$(_conv_hub 'BeschleunigerBallett | .github/workflows/Linux.yml | job-timeout | asan | a row about a tree this run cannot see')"
_foreign() { _conv_at "${hub2}" "${clean_root}"; }
t_assert_eq "0" "$(t_rc _foreign)"
t_assert_contains "$(t_out _foreign)" "1 for other repositories"

t_case "a row naming a repository consumers.json does not declare is a typo, and fails"
hub3="$(_conv_hub 'OxidAnt | .github/workflows/ci.yml | job-timeout | build | lower-cased the ANT')"
t_assert_eq "1" "$(t_rc _conv_at "${hub3}" "${clean_root}")" \
  "a misspelled repo column would silently grade nothing, forever"
t_assert_contains "$(t_out _conv_at "${hub3}" "${clean_root}")" \
  "consumers.json does not declare"

t_case "a row with no reason is not an excuse"
hub4="$(_conv_hub 'OxidANT | .github/workflows/ci.yml | job-timeout | build |')"
t_assert_eq "1" "$(t_rc _conv_at "${hub4}" "${ramped}")"
t_assert_contains "$(t_out _conv_at "${hub4}" "${ramped}")" "a row with no reason is not an excuse"

t_case "a row naming a check that does not exist is refused"
hub5="$(_conv_hub 'OxidANT | .github/workflows/ci.yml | job-timeouts | build | typo in the check column')"
t_assert_eq "1" "$(t_rc _conv_at "${hub5}" "${ramped}")"
t_assert_contains "$(t_out _conv_at "${hub5}" "${ramped}")" "unknown check"

t_case "the same deviation excused twice is a bookkeeping error"
hub6="$(_conv_hub "${_ROW}
${_ROW}")"
t_assert_eq "1" "$(t_rc _conv_at "${hub6}" "${ramped}")" \
  "two reasons for one deviation means one of them is unread"
t_assert_contains "$(t_out _conv_at "${hub6}" "${ramped}")" "duplicate row"

t_case "a workflow the parser cannot READ fails, and is not graded advisory"
# The subset stops at anchors and aliases. Reporting a file it could not read as
# three passing conventions is the exact shape this gate exists to refuse, so
# the pseudo-check never ramps.
d="$(_conv_root OxidANT 'name: ci
on: push
permissions: &p
  contents: read
jobs:
  build:
    runs-on: ubuntu-24.04
    timeout-minutes: 5
    steps:
      - run: echo hi')"
t_assert_eq "1" "$(t_rc _conv "${d}")" \
  "unarmed is exactly when an unreadable workflow would otherwise pass as clean"
_out="$(t_out _conv "${d}")"
t_assert_contains "${_out}" "[parse]"
t_assert_contains "${_out}" "NONE of the four conventions was graded over it"

t_case "a root with no .github refuses rather than reporting green over nothing"
empty="$(mktemp -d "${_work}/empty.XXXXXX")"
git -C "${empty}" init -q
t_assert_eq "1" "$(t_rc _conv "${empty}")" \
  "an empty file list is a wrong root, not a clean repository"
t_assert_contains "$(t_out _conv "${empty}")" "wrong root?"

# --- the parser: the subset has to be the subset it claims -------------------
# Every case below was once a SILENT wrong answer: the gate printed a verdict and
# exited 0 over a file it had mis-read. That is worse than an unenforced
# convention, because it looks exactly like a clean bill.

# A ceiling no fixture here can reach, so a ratchet verdict never lands in the
# middle of a parser case and gets read as a parse one.
_CEIL='CENSUS | OxidANT | job-timeout | 9 | a fixture ceiling: these cases are about the parser, not the ratchet
CENSUS | OxidANT | permissions | 9 | a fixture ceiling
CENSUS | OxidANT | artifact-error | 9 | a fixture ceiling'
phub="$(_conv_hub "${_CEIL}")"
_p() { _conv_at "${phub}" "$1"; }
_p_armed() { WORKFLOW_CONVENTIONS_GATE=1 _conv_at "${phub}" "$1"; }

t_case "a block sequence at the SAME column as its key is read, not dropped"
# `steps:` with its entries flush underneath is ordinary, valid Actions YAML.
# Demanding a strictly deeper child parsed it as an empty key, so this upload
# step -- which sets no if-no-files-found at all -- was invisible, and the file
# was reported clean on all four conventions with rc 0.
d="$(_conv_root OxidANT 'name: ci
on: push
permissions:
  contents: read
jobs:
  build:
    runs-on: ubuntu-24.04
    timeout-minutes: 5
    steps:
    - uses: actions/upload-artifact@v7
      with:
        name: out
        path: dist')"
t_assert_contains "$(t_out _p "${d}")" "[artifact-error] upload-artifact step" \
  "a dropped steps: list is a clean bill over an upload that can ship nothing and stay green"
t_assert_eq "1" "$(t_rc _p_armed "${d}")"

t_case "...and a same-column sequence does not truncate the keys after it"
# The other half of the same bug. A matrix `include:` written flush swallowed the
# rest of its job, so the gate reported "no timeout-minutes" for a job that HAS
# one and missed the windows-latest two lines above it at the same time.
d="$(_conv_root OxidANT 'name: ci
on: push
permissions:
  contents: read
jobs:
  build:
    strategy:
      matrix:
        include:
        - runs_on: windows-latest
    runs-on: ${{ matrix.runs_on }}
    timeout-minutes: 5
    steps:
      - run: echo hi')"
_out="$(t_out _p "${d}")"
t_assert_contains "${_out}" "runner label 'windows-latest'"
t_assert_fails grep -q -F -e '[job-timeout]' <<<"${_out}" \
  "the job carries timeout-minutes: 5, so reporting it missing IS the truncation"

t_case "a flow sequence is READ, so a banned label inside one cannot hide"
# `runs-on: [ubuntu-latest]` fell through as one opaque string: clean report,
# rc 0, over the one convention this gate enforces with no knob at all.
d="$(_conv_root OxidANT 'name: ci
on: [push, pull_request]
permissions:
  contents: read
jobs:
  build:
    runs-on: [ubuntu-latest]
    timeout-minutes: 5
    steps:
      - run: echo hi')"
t_assert_eq "1" "$(t_rc _p "${d}")"
t_assert_contains "$(t_out _p "${d}")" "runner label 'ubuntu-latest'"

t_case "a flow MAPPING is read too, jobs and all"
d="$(_conv_root OxidANT 'name: ci
on: push
permissions: {contents: read}
jobs: {build: {runs-on: ubuntu-latest, timeout-minutes: 5, steps: [{run: echo hi}]}}')"
t_assert_eq "1" "$(t_rc _p "${d}")"
t_assert_contains "$(t_out _p "${d}")" "runner label 'ubuntu-latest'"

t_case "a flow collection outside the subset REFUSES rather than guessing"
# One that spans lines. The header promises that anything outside the subset
# raises; a gate that guesses at its input is worse than one that says it cannot
# read the file.
d="$(_conv_root OxidANT 'name: ci
on: push
permissions:
  contents: read
jobs:
  build:
    runs-on: [
      ubuntu-24.04 ]
    timeout-minutes: 5
    steps:
      - run: echo hi')"
t_assert_eq "1" "$(t_rc _p "${d}")"
t_assert_contains "$(t_out _p "${d}")" "[parse]"

t_case "an EMPTY workflow file is a file nothing graded, not four clean conventions"
d="$(_conv_root OxidANT '')"
t_assert_eq "1" "$(t_rc _p "${d}")" \
  "reporting all four conventions clean over an empty file is the vacuous pass this gate exists to refuse"
_out="$(t_out _p "${d}")"
t_assert_contains "${_out}" "[parse]"
t_assert_contains "${_out}" "no YAML at all"

t_case "a line the walk never reached is a refusal, not a shorter document"
# Whatever the walk leaves behind was graded by nothing, and a mapping that ends
# early is exactly how a truncation reports four clean conventions over half a
# file. Here a mis-indented key sits under no parent at all.
d="$(_conv_root OxidANT 'name: ci
on: push
permissions:
  contents: read
jobs:
  build:
    runs-on: ubuntu-24.04
    timeout-minutes: 5
    steps:
      - run: echo hi
 trailing: indented past the top level and under nothing')"
t_assert_eq "1" "$(t_rc _p "${d}")"
t_assert_contains "$(t_out _p "${d}")" "outside the document the walk read"

t_case "a repository consumers.json does not declare is refused, not graded half-way"
# Every allow row -- excuse and CENSUS alike -- is keyed on this name, so under an
# undeclared one neither can ever be written: the findings would be graded with
# the whole bookkeeping half disconnected, and the gate would still print OK.
d="$(_conv_root NotAConsumer "${_CONV_CLEAN}")"
t_assert_eq "1" "$(t_rc _p "${d}")"
t_assert_contains "$(t_out _p "${d}")" "not declared in .github/consumers.json"

t_case "WORKFLOW_CONVENTIONS_GATE=0 disarms the ramp instead of failing to parse"
# The obvious way to switch a ramp off was a hard FAIL ("names unknown check(s):
# 0"), which teaches people to delete the call rather than turn the knob down.
_off() { WORKFLOW_CONVENTIONS_GATE=0 _conv_at "${phub}" "$1"; }
t_assert_eq "0" "$(t_rc _off "${ramped}")"
t_assert_contains "$(t_out _off "${ramped}")" "advisory artifact-error,job-timeout,permissions"

t_case "a consumers.json that cannot be READ fails; the typo check may not switch itself off"
# It used to swallow OSError/ValueError and return an empty set, which silently
# disabled the allow file's repo-column check: checks nothing, reports green.
nocons="$(mktemp -d "${_work}/nocons.XXXXXX")"
install -D -m 0644 "${CONV}" "${nocons}/linux/scripts/verify_workflow_conventions.py"
printf '%s\n' "${_CEIL}" > "${nocons}/linux/scripts/workflow-conventions.allow"
t_assert_eq "1" "$(t_rc _conv_at "${nocons}" "${clean_root}")"
t_assert_contains "$(t_out _conv_at "${nocons}" "${clean_root}")" "cannot read"

t_case "...and one that is not valid JSON fails the same way"
badcons="$(_conv_hub "${_CEIL}")"
printf '%s\n' '{ "consumers": [' > "${badcons}/.github/consumers.json"
t_assert_eq "1" "$(t_rc _conv_at "${badcons}" "${clean_root}")"
t_assert_contains "$(t_out _conv_at "${badcons}" "${clean_root}")" "not valid JSON"

# --- the census ratchet ------------------------------------------------------
# The ramp only promises to REPORT. The census is what stops the reported backlog
# growing: frozen per repository per check, and it may only go down.

t_case "a NEW finding over the frozen count FAILS while its check is still advisory"
hubc="$(_conv_hub 'CENSUS | OxidANT | job-timeout | 1 | one lane, the ceiling for this fixture')"
two_off="$(_conv_root OxidANT 'name: ci
on: push
permissions:
  contents: read
jobs:
  a:
    runs-on: ubuntu-24.04
    steps:
      - run: echo hi
  b:
    runs-on: ubuntu-24.04
    steps:
      - run: echo hi')"
t_assert_eq "1" "$(t_rc _conv_at "${hubc}" "${two_off}")" \
  "advisory with no ceiling is a backlog that grows for ever with nothing turning red"
t_assert_contains "$(t_out _conv_at "${hubc}" "${two_off}")" "GREW from 1 to 2"

t_case "findings with NO census row fail: the ratchet cannot be skipped by omission"
hubd="$(_conv_hub '# a table with no rows at all')"
t_assert_eq "1" "$(t_rc _conv_at "${hubd}" "${ramped}")"
t_assert_contains "$(t_out _conv_at "${hubd}" "${ramped}")" "has no CENSUS row for it"

t_case "a count that went DOWN in a consumer is reported with its number, and passes"
# The corpus is other repositories' workflows and they cannot edit this table, so
# a consumer that FIXED a workflow must not go red waiting for a hub commit.
hube="$(_conv_hub 'CENSUS | OxidANT | job-timeout | 9 | deliberately above the fixture, to drive the shrink arm')"
t_assert_eq "0" "$(t_rc _conv_at "${hube}" "${one_off}")"
t_assert_contains "$(t_out _conv_at "${hube}" "${one_off}")" "RATCHET [job-timeout] is down to 1"

# A tree whose `origin` names the HUB, which is the half of the ratchet that is
# strict: this repository's commit can edit the row beside the fix.
hub_root="$(_conv_root ContainerHub 'name: ci
on: push
permissions:
  contents: read
jobs:
  build:
    runs-on: ubuntu-24.04
    steps:
      - run: echo hi')"

t_case "...but an unrecorded shrink in the HUB fails, like every other allow file here"
hubf="$(_conv_hub 'CENSUS | ContainerHub | job-timeout | 4 | above the fixture on purpose')"
t_assert_eq "1" "$(t_rc _conv_at "${hubf}" "${hub_root}")"
t_assert_contains "$(t_out _conv_at "${hubf}" "${hub_root}")" \
  "down to 1 in ContainerHub from a frozen 4"

t_case "an ARMED check counts zero, so arming one retires its row instead of double-reporting"
hubg="$(_conv_hub 'CENSUS | ContainerHub | job-timeout | 1 | the row arming is expected to retire')"
_hub_armed() { WORKFLOW_CONVENTIONS_GATE=job-timeout _conv_at "${hubg}" "$1"; }
t_assert_eq "1" "$(t_rc _hub_armed "${hub_root}")"
_out="$(t_out _hub_armed "${hub_root}")"
t_assert_contains "${_out}" "FAIL: .github/workflows/ci.yml:6 [job-timeout]" \
  "once a check is armed the finding itself is the verdict"
t_assert_contains "${_out}" "delete the row" \
  "a frozen count nothing grades any more is how a baseline rots"

t_case "a CENSUS row whose count is not a number is refused"
hubh="$(_conv_hub 'CENSUS | OxidANT | job-timeout | some | not a number')"
t_assert_eq "1" "$(t_rc _conv_at "${hubh}" "${clean_root}")"
t_assert_contains "$(t_out _conv_at "${hubh}" "${clean_root}")" "is not a number"

t_case "a CENSUS row with no reason is not a baseline"
hubi="$(_conv_hub 'CENSUS | OxidANT | job-timeout | 1 |')"
t_assert_eq "1" "$(t_rc _conv_at "${hubi}" "${clean_root}")"
t_assert_contains "$(t_out _conv_at "${hubi}" "${clean_root}")" "not a baseline"

t_case "the same check frozen twice for one repository is a bookkeeping error"
hubj="$(_conv_hub 'CENSUS | OxidANT | job-timeout | 1 | the first
CENSUS | OxidANT | job-timeout | 2 | the second')"
t_assert_eq "1" "$(t_rc _conv_at "${hubj}" "${clean_root}")"
t_assert_contains "$(t_out _conv_at "${hubj}" "${clean_root}")" "duplicate CENSUS row"

t_case "a CENSUS row naming a repository consumers.json does not declare is a typo"
hubk="$(_conv_hub 'CENSUS | OxidAnt | job-timeout | 1 | lower-cased the ANT')"
t_assert_eq "1" "$(t_rc _conv_at "${hubk}" "${clean_root}")"
t_assert_contains "$(t_out _conv_at "${hubk}" "${clean_root}")" "consumers.json does not declare"

t_case "preflight ARMS the ramp; a knob with no caller ramps nothing"
# WORKFLOW_CONVENTIONS_GATE had zero callers anywhere in the fleet when it
# landed, which made "advisory until armed" a promise nobody could keep.
t_assert_contains "$(cat "${SCRIPTS}/preflight.sh")" \
  "env WORKFLOW_CONVENTIONS_GATE=permissions bash linux/scripts/lint-workflows.sh"

t_case "the SHIPPED allow file parses and its census is EXACT for this repo"
# The excuse table ships empty; the census does not, and a number that is merely
# typed rots. Requiring rc 0 over this repo's own .github is what makes the
# shipped counts a measurement rather than a claim.
# THIS TREE's workflows under an `origin` that names this repository: the
# mutation gate runs this suite from a throwaway COPY with no .git in it at all,
# where the gate rightly refuses a tree it cannot key a single allow row to.
hub_probe="$(mktemp -d "${_work}/hubprobe.XXXXXX")"
cp -r "${SCRIPTS}/../../.github" "${hub_probe}/.github"
git -C "${hub_probe}" init -q
git -C "${hub_probe}" remote add origin "https://github.com/Kataglyphis/ContainerHub.git"
_out="$(t_out _conv "${hub_probe}")"
t_assert_contains "${_out}" "workflow conventions under"
t_assert_fails grep -q -F -e "expected '<repo>" <<<"${_out}"
t_assert_fails grep -q -F -e 'unknown check' <<<"${_out}"
t_assert_eq "0" "$(t_rc _conv "${hub_probe}")" \
  "a shipped census that does not match the tree it was measured from is already stale"

t_summary
