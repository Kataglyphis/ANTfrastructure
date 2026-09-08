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

# _gh_tree <action image default | ""> <workflow text> -> a consumer-shaped
# .github/ with ONE of the four container actions and one workflow.
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
  t_assert_contains "$(t_out _gate "${_d}")" "wrong root?"
else
  t_assert_eq "no-python" "no-python" "PREFLIGHT_PYTHON unset and python3 is a stub"
fi

t_summary
