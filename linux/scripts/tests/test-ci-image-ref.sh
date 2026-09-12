#!/usr/bin/env bash
# Tests for ci-image-ref.sh. The hazard is an EMPTY or WRONG reference reaching
# `docker run`, where an empty string is read as "run the next argument as an
# image" and a wrong tag pulls someone else's toolchain - both failing far from
# the cause. So: stdout carries the ref and nothing else, a missing key is fatal
# rather than empty, and the value AGREES with verify_ci_image_refs.py, which is
# what grades the four composite actions' `image:` defaults.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SCRIPTS="${TESTS_DIR}/.."
REF="${SCRIPTS}/ci-image-ref.sh"
VERSIONS="${SCRIPTS}/01-core/versions.env"

_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT

t_case "the Linux ref is composed from versions.env, on stdout, alone"
_prefix="$(sed -n 's/^IMAGE_REGISTRY_PREFIX=//p' "${VERSIONS}" | tail -n 1)"
_linux_tag="$(sed -n 's/^CI_IMAGE_LINUX_TAG=//p' "${VERSIONS}" | tail -n 1)"
_win_tag="$(sed -n 's/^CI_IMAGE_WINDOWS_TAG=//p' "${VERSIONS}" | tail -n 1)"
t_assert_eq "${_prefix}:${_linux_tag}" "$(bash "${REF}")" \
  "the default must be the Linux image; every local repro depends on it"
t_assert_eq "${_prefix}:${_linux_tag}" "$(bash "${REF}" --linux)"
t_assert_eq "${_prefix}:${_win_tag}" "$(bash "${REF}" --windows)"

t_case "stderr is not stdout: nothing but the ref can reach a command substitution"
t_assert_eq "1" "$(bash "${REF}" 2>/dev/null | wc -l)" \
  "a second stdout line would be concatenated into the image argument"

# The gate and the script must not be able to disagree: they read the same file
# with two different parsers, and the four action defaults are graded against
# the gate's answer, not this one.
t_case "the composed ref equals verify_ci_image_refs.py's"
_py="${PREFLIGHT_PYTHON:-python3}"
# Probed ONCE: the gate half at the bottom of this file needs the same answer,
# and the system python3 here is a Microsoft Store stub that exits 49.
_have_py=0
command -v "${_py}" >/dev/null 2>&1 && "${_py}" -c pass >/dev/null 2>&1 && _have_py=1
if [ "${_have_py}" -eq 1 ]; then
  _gate_out="$("${_py}" "${SCRIPTS}/verify_ci_image_refs.py" "${SCRIPTS}/../.." 2>&1)"
  t_assert_contains "${_gate_out}" "linux   $(bash "${REF}")"
  t_assert_contains "${_gate_out}" "windows $(bash "${REF}" --windows)"
else
  t_assert_eq "no-python" "no-python" "PREFLIGHT_PYTHON unset and python3 is a stub"
fi

t_case "a missing key is FATAL and prints nothing on stdout"
printf 'IMAGE_REGISTRY_PREFIX=ghcr.io/x/y\n' > "${_work}/partial.env"
t_assert_eq "1" "$(CI_IMAGE_REF_VERSIONS_ENV="${_work}/partial.env" t_rc bash "${REF}")" \
  "an empty ref is the failure this refuses to produce"
t_assert_eq "" "$(CI_IMAGE_REF_VERSIONS_ENV="${_work}/partial.env" bash "${REF}" 2>/dev/null)"
# ...and it must actually SAY so. The key reader's stdout is its return VALUE:
# it is read inside a command substitution, so a diagnostic printed there
# without >&2 is captured into that value instead of reaching anybody, and the
# gate fails in silence. Asserting the exit code alone cannot see that.
_err="$(CI_IMAGE_REF_VERSIONS_ENV="${_work}/partial.env" bash "${REF}" 2>&1 >/dev/null)"
t_assert_contains "${_err}" "CI_IMAGE_LINUX_TAG is not set" \
  "the missing key must be named on stderr, not swallowed by the substitution"
t_assert_contains "${_err}" "partial.env" "and so must the file it looked in"

t_case "a missing versions.env is FATAL and names the submodule fix"
_out="$(CI_IMAGE_REF_VERSIONS_ENV="${_work}/absent.env" t_out bash "${REF}")"
t_assert_eq "1" "$(CI_IMAGE_REF_VERSIONS_ENV="${_work}/absent.env" t_rc bash "${REF}")"
t_assert_contains "${_out}" "git submodule update --init"

t_case "an unknown argument is a usage error (2), not a silent Linux default"
t_assert_eq "2" "$(t_rc bash "${REF}" --darwin)" \
  "defaulting a typo to Linux would run the wrong lane and report success"

t_case "quoted values in versions.env are unwrapped, not carried into the ref"
printf 'IMAGE_REGISTRY_PREFIX="ghcr.io/x/y"\nCI_IMAGE_LINUX_TAG='"'"'tag1'"'"'\n' > "${_work}/quoted.env"
t_assert_eq "ghcr.io/x/y:tag1" \
  "$(CI_IMAGE_REF_VERSIONS_ENV="${_work}/quoted.env" bash "${REF}")" \
  "a quote reaching docker as data is the class that broke CUDA_ARCHITECTURES"

# --- verify_ci_image_refs.py's own three findings ----------------------------
# Everything above (and test-workflow-lint.sh's fixture) proves only that the
# gate RUNS and agrees on the value. Nothing planted a WRONG one, so its three
# checks could all have been neutered without a suite noticing -- the shape this
# repo keeps finding. Each case below plants exactly one wrong value and asserts
# the gate goes red on it.

# _gh_tree <action image default | ""> <workflow text> [<relpath>=<body> ...]
#   -> a consumer-shaped .github/ with ONE of the four container actions, one
#      workflow, and any extra files the case needs.
#
# git init + add, because check D reads the git INDEX (gate_scope rule 3), not a
# walk: a walk of a working tree picks up .venv/ and build dirs. The "an
# UNTRACKED file" case below is what proves that is what actually happens.
_gh_tree() {
  local d
  d="$(mktemp -d "${_work}/gh.XXXXXX")"
  mkdir -p "${d}/.github/actions/run-in-linux-container" "${d}/.github/workflows"
  {
    printf 'name: run-in-linux-container\ndescription: fixture\ninputs:\n'
    printf '  image:\n    description: image to run\n    required: false\n'
    [ -n "$1" ] && printf '    default: %s\n' "$1"
    printf 'runs:\n  using: composite\n  steps:\n    - run: "true"\n      shell: bash\n'
  } > "${d}/.github/actions/run-in-linux-container/action.yml"
  printf '%s\n' "$2" > "${d}/.github/workflows/ci.yml"
  shift 2
  local spec rel
  for spec in "$@"; do
    rel="${spec%%=*}"
    mkdir -p "${d}/$(dirname "${rel}")"
    printf '%s\n' "${spec#*=}" > "${d}/${rel}"
  done
  git -C "${d}" init -q
  git -C "${d}" add -A
  printf '%s' "${d}"
}

_WF_CLEAN='name: ci
on: push
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: echo hello'

_gate() { "${_py}" "${SCRIPTS}/verify_ci_image_refs.py" "$1"; }

if [ "${_have_py}" -eq 1 ]; then
  _linux_ref="${_prefix}:${_linux_tag}"
  _win_ref="${_prefix}:${_win_tag}"

  t_case "the fixture itself is sound: a correct .github/ passes"
  # Without this the four refusals below could each be passing for the wrong
  # reason -- a fixture the gate rejects on some other line.
  _d="$(_gh_tree "${_linux_ref}" "${_WF_CLEAN}")"
  t_assert_eq "0" "$(t_rc _gate "${_d}")" \
    "the canonical default plus a literal-free workflow must be green"

  t_case "an action default that is not ITS platform's ref FAILS"
  # The default is the WINDOWS ref, on the Linux action: a perfectly canonical
  # tag, so the literal check waves it through. Only the comparison against the
  # ref versions.env composes for THIS action can see it -- which is why the
  # case cannot use a stale tag: that one is caught by the literal check, and
  # would pass with the comparison removed.
  _d="$(_gh_tree "${_win_ref}" "${_WF_CLEAN}")"
  t_assert_eq "1" "$(t_rc _gate "${_d}")" \
    "a tag bump lands in versions.env only; a copy that stopped matching it is the drift this gate exists for"
  _out_a="$(t_out _gate "${_d}")"
  t_assert_contains "${_out_a}" "run-in-linux-container/action.yml"
  t_assert_contains "${_out_a}" "versions.env composes ${_linux_ref}"

  t_case "an image input with NO default FAILS"
  _d="$(_gh_tree "" "${_WF_CLEAN}")"
  t_assert_eq "1" "$(t_rc _gate "${_d}")" \
    "without a default every caller re-types the tag, which is where the copies drift apart"
  t_assert_contains "$(t_out _gate "${_d}")" "no \`default:\`"

  t_case "a non-canonical image literal anywhere under .github/ FAILS"
  _d="$(_gh_tree "${_linux_ref}" "${_WF_CLEAN}
      - run: docker run --rm ${_prefix}:latest true")"
  t_assert_eq "1" "$(t_rc _gate "${_d}")" \
    "':latest' has no per-platform children any more; it must fail here, not at docker pull in someone else's lane"
  t_assert_contains "$(t_out _gate "${_d}")" "non-canonical image tag ':latest'"

  t_case "a CANONICAL tag for the wrong platform at a call site FAILS"
  _d="$(_gh_tree "${_linux_ref}" "${_WF_CLEAN}
      - uses: ./.github/actions/run-in-linux-container
        with:
          image: ${_win_ref}")"
  t_assert_eq "1" "$(t_rc _gate "${_d}")" \
    "both tags are canonical, so the literal check cannot see this: a Linux action handed the Windows image"
  t_assert_contains "$(t_out _gate "${_d}")" "it must run ${_linux_ref}"

  t_case "no workflow or action YAML at all is a refusal, not a green"
  _d="$(mktemp -d "${_work}/empty.XXXXXX")"
  t_assert_eq "1" "$(t_rc _gate "${_d}")" \
    "a gate that graded nothing must say so; the usual cause is the wrong root"
  t_assert_contains "$(t_out _gate "${_d}")" "wrong root?" \
    "and it must say it BEFORE the git-index scan, whose message names the wrong problem"

  # --- check D: a COPY of a currently-canonical ref -------------------------
  # A/B/C were blind to this class and said so in green: the three copies that
  # survived (two workflow `env:` entries and a PowerShell param default) were
  # CANONICAL, so B waved them through and C only ever compares platforms.

  t_case "a canonical ref spelled out in a tracked *.sh FAILS"
  _d="$(_gh_tree "${_linux_ref}" "${_WF_CLEAN}" \
    "scripts/run.sh=#!/usr/bin/env bash
docker run ${_linux_ref} true")"
  t_assert_eq "1" "$(t_rc _gate "${_d}")" \
    "shell has ci-image-ref.sh to ask; a ref typed here is frozen at today's tag"
  _out_d="$(t_out _gate "${_d}")"
  t_assert_contains "${_out_d}" "scripts/run.sh:2"
  t_assert_contains "${_out_d}" "ci-image-ref.sh" "the finding must name the owner to ask"

  t_case "a canonical ref in a tracked *.ps1 FAILS, and names the PowerShell owner"
  _d="$(_gh_tree "${_linux_ref}" "${_WF_CLEAN}" \
    "scripts/Build.ps1=param([string]\$Image = '${_win_ref}')")"
  t_assert_eq "1" "$(t_rc _gate "${_d}")" \
    "a param default is exactly where the Windows copy hid"
  t_assert_contains "$(t_out _gate "${_d}")" "Get-CiImageReference" \
    "pointing a PowerShell caller at a bash script would be useless advice"

  t_case "a COMMENT copy fails too: that is where two of the three were"
  _d="$(_gh_tree "${_linux_ref}" "${_WF_CLEAN}" \
    "scripts/doc.sh=#!/usr/bin/env bash
# Runs in ${_linux_ref}.
true")"
  t_assert_eq "1" "$(t_rc _gate "${_d}")" \
    "a ref in a comment rots on a tag bump exactly like one in code"

  t_case "a per-arch CHILD of the family tag in a script is NOT a copy"
  # The build chain really does produce and run these, and D must not turn into
  # "no ghcr reference anywhere" -- that would only teach people to excuse it.
  _d="$(_gh_tree "${_linux_ref}" "${_WF_CLEAN}" \
    "scripts/smoke.sh=#!/usr/bin/env bash
docker run ${_linux_ref}-arm64 true")"
  t_assert_eq "0" "$(t_rc _gate "${_d}")" \
    "a tag that merely STARTS with the canonical one is a different image"

  t_case "an UNTRACKED file is not graded: the index is the scope, not the disk"
  # Measured before choosing: a walk of one consumer's tree yields 38 *.sh under
  # .venv/, build-*/ and .pub-cache/ against 21 tracked ones, and would report a
  # vendored dependency's shell as this repo's drift.
  _d="$(_gh_tree "${_linux_ref}" "${_WF_CLEAN}")"
  mkdir -p "${_d}/.venv/bin"
  printf 'docker run %s true\n' "${_linux_ref}" > "${_d}/.venv/bin/activate.sh"
  t_assert_eq "0" "$(t_rc _gate "${_d}")" \
    "grading untracked build output makes the gate unrunnable on a dev box"

  t_case "a script under third_party/ belongs to that repo's own run"
  _d="$(_gh_tree "${_linux_ref}" "${_WF_CLEAN}" \
    "third_party/ANTfrastructure/linux/scripts/x.sh=docker run ${_linux_ref} true")"
  t_assert_eq "0" "$(t_rc _gate "${_d}")" \
    "a submodule is a separate root; double-reporting it makes both verdicts noise"

  t_case "the family ref hoisted into a workflow env: FAILS"
  _WF_ENV='name: ci
on: push
env:
  CONTAINER_IMAGE: REF_HERE
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: echo hello'
  _d="$(_gh_tree "${_linux_ref}" "${_WF_ENV//REF_HERE/${_linux_ref}}")"
  t_assert_eq "1" "$(t_rc _gate "${_d}")" \
    "this is the exact shape three lanes carried while the gate reported green"
  _out_d="$(t_out _gate "${_d}")"
  t_assert_contains "${_out_d}" "workflows/ci.yml:4"
  t_assert_contains "${_out_d}" "omit the input" "the finding must name the way out"

  t_case "the two YAML forms with nowhere else to get the value stay green"
  # D's ONE carve-out is `default:` -- an input's owner. A reusable workflow's
  # input default and an expression fallback are how a caller keeps an override,
  # and neither can inherit an action default. If this case ever goes red, D has
  # stopped being a rule about copies and become a ban on the string.
  _WF_OWNER='name: ci
on:
  workflow_call:
    inputs:
      container-image:
        type: string
        default: REF_HERE
jobs:
  build:
    runs-on: ubuntu-latest
    env:
      CONTAINER_IMAGE: ${{ inputs.container-image || '"'"'REF_HERE'"'"' }}
    steps:
      - run: echo hello'
  _d="$(_gh_tree "${_linux_ref}" "${_WF_OWNER//REF_HERE/${_linux_ref}}")"
  t_assert_eq "0" "$(t_rc _gate "${_d}")" \
    "an input default IS the owner of that value; an expression leaves the caller a choice"
else
  t_assert_eq "no-python" "no-python" "PREFLIGHT_PYTHON unset and python3 is a stub"
fi

t_summary
