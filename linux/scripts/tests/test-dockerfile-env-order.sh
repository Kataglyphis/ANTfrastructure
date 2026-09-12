#!/usr/bin/env bash
# Tests for verify_dockerfile_env_order.py and its wiring into lint-dockerfiles.sh,
# plus the Android env contract the shipped runtime image owes its consumers.
# Fixtures are written to a temp dir; the real tree is only READ.
# docs/code-quality-tooling.md#env-instruction-ordering-dockerfile-lint
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
REPO_ROOT="$(cd "${TESTS_DIR}/../../.." && pwd)"
GATE="${REPO_ROOT}/linux/scripts/verify_dockerfile_env_order.py"
LINTER="${REPO_ROOT}/linux/scripts/lint-dockerfiles.sh"
PKG="${REPO_ROOT}/linux/Dockerfile.package"
PY="${PREFLIGHT_PYTHON:-python3}"

_fixture() {
  local d; d="$(mktemp -d)"
  printf '%s\n' "$1" > "${d}/Dockerfile.fix"
  printf '%s' "${d}"
}
_run() { t_out "${PY}" "${GATE}" "$1/Dockerfile.fix"; }
_rc()  { t_rc  "${PY}" "${GATE}" "$1/Dockerfile.fix"; }

# The offending shape, once: two keys in ONE instruction, the second reading the
# first. $1 is spliced mid-continuation, where BuildKit drops comment lines; $2
# replaces the line break before PATH, which is what splitting the ENV means.
_two_keys() {
  printf 'FROM scratch\nENV ANDROID_HOME=/opt/android-sdk%s\n%sPATH="${ANDROID_HOME}/platform-tools:${PATH}"' \
    "${2- \\}" "$1"
}

t_case "gate exists and parses"
t_assert_ok test -f "${GATE}"
t_assert_ok "${PY}" -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "${GATE}"

t_case "the live defect: a later key reading an earlier one in the SAME ENV fails"
fix="$(_fixture "$(_two_keys '    ')")"
out="$(_run "${fix}")"
t_assert_eq "1" "$(_rc "${fix}")"
t_assert_contains "${out}" 'ENV PATH reads ${ANDROID_HOME}, set in the SAME instruction'
t_assert_contains "${out}" "Dockerfile.fix:2:"
rm -rf "${fix}"

t_case "splitting the instruction in two is the fix, and passes"
fix="$(_fixture "$(_two_keys 'ENV ' '')")"
t_assert_eq "0" "$(_rc "${fix}")"
rm -rf "${fix}"

t_case "self-reference is the inherit-and-extend idiom, not a finding"
fix="$(_fixture 'FROM scratch
ENV PATH="/opt/bin:${PATH}"')"
t_assert_eq "0" "$(_rc "${fix}")"
rm -rf "${fix}"

t_case "a name that is also an ARG in scope resolves from the ARG"
fix="$(_fixture 'FROM scratch
ARG GCC_VERSION=16.2.0
ENV GCC_VERSION=${GCC_VERSION} \
    GCC_PREFIX=/opt/gcc-${GCC_VERSION}')"
t_assert_eq "0" "$(_rc "${fix}")"
rm -rf "${fix}"

t_case "ARG scope resets at FROM, so a later stage's ENV is not excused"
fix="$(_fixture 'FROM scratch AS one
ARG CUDA_HOME=/usr/local/cuda
FROM scratch AS two
ENV CUDA_HOME=/usr/local/cuda \
    PATH="${CUDA_HOME}/bin:${PATH}"')"
t_assert_eq "1" "$(_rc "${fix}")"
rm -rf "${fix}"

t_case "comment lines inside a continued ENV do not end the instruction"
fix="$(_fixture "$(_two_keys '    # a note that BuildKit drops
    ')")"
t_assert_eq "1" "$(_rc "${fix}")"
rm -rf "${fix}"

t_case "a clean file reports the count it actually read, never a silent pass"
fix="$(_fixture 'FROM scratch
ENV A=1')"
t_assert_contains "$(_run "${fix}")" "ok: ENV ordering (1 Dockerfile(s))"
rm -rf "${fix}"

t_case "no targets is a usage error, not a vacuous pass"
t_assert_eq "2" "$(t_rc "${PY}" "${GATE}")"

t_case "a target that is not a file fails instead of being skipped"
t_assert_eq "1" "$(t_rc "${PY}" "${GATE}" /nonexistent/Dockerfile.nope)"

t_case "lint-dockerfiles.sh actually runs the gate (an orphaned gate proves nothing)"
t_assert_ok grep -q 'python3 linux/scripts/verify_dockerfile_env_order.py "${DOCKERFILES\[@\]}"' "${LINTER}"

t_case "the whole shipped Dockerfile set is clean"
_all=()
for _df in "${REPO_ROOT}"/linux/Dockerfile.* "${REPO_ROOT}"/linux/webserver/Dockerfile \
           "${REPO_ROOT}"/linux/llm-stack/Dockerfile "${REPO_ROOT}"/windows/Dockerfile*; do
  [ -f "${_df}" ] && _all+=("${_df}")
done
t_assert_ok test "${#_all[@]}" -ge 20
t_assert_ok "${PY}" "${GATE}" "${_all[@]}"

# The consumer contract: smoke-runtime-image.sh asserts ANDROID_HOME in the BUILT
# image; only this file can assert the Dockerfile ever sets it.
t_case "Dockerfile.package advertises ANDROID_HOME and ANDROID_SDK_ROOT"
t_assert_ok grep -qE '^ENV ANDROID_HOME=/opt/android-sdk ' "${PKG}"
t_assert_ok grep -qE '^ +ANDROID_SDK_ROOT=/opt/android-sdk$' "${PKG}"

t_case "the advertised root is a tree this Dockerfile actually copies in"
t_assert_ok grep -qE '^COPY .*--from=artifact-source /opt/android-sdk /opt/android-sdk$' "${PKG}"

t_case "the android PATH entries are APPENDED, never fronted"
_p="$(grep -E '^ENV PATH="\$\{PATH\}' "${PKG}")"
t_assert_contains "${_p}" '${ANDROID_HOME}/cmdline-tools/latest/bin'
t_assert_contains "${_p}" '${ANDROID_HOME}/platform-tools'
t_assert_eq 'ENV PATH="${PATH}' "$(printf '%s' "${_p}" | cut -c1-17)"

t_case "build-tools stays off PATH: it ships an lld that would front /usr/bin/lld"
t_assert_fails grep -q 'ANDROID_HOME}/build-tools' "${PKG}"

# --- lint-dockerfiles.sh over a CONSUMER tree (--root) ------------------------
# Same contract as lint-workflows.sh / lint-shell.sh / lint-python.sh, and the
# same reason: a submodule checkout puts the gate inside the consumer, where the
# default root resolves to ANTfrastructure, all 24 of ITS Dockerfiles get graded
# and the verdict is reported as the consumer's.
_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT
# `broken` and `vendored` both carry the live ENV-ordering defect this file is
# otherwise about, so a green verdict over a tree holding the vendored one
# proves the scope excluded it rather than that it was clean.
_plant() {  # <dir> <shape>
  case "$2" in
    clean)           printf 'FROM scratch\nENV A=1\n' > "$1/Dockerfile"
                     mkdir -p "$1/svc"
                     printf 'FROM scratch\nENV B=1\n' > "$1/svc/Dockerfile.web" ;;
    broken|vendored) printf '%s\n' "$(_two_keys '    ')" > "$1/Dockerfile" ;;
    empty)           printf 'no dockerfiles here\n' > "$1/README.md" ;;
  esac
}
# _consumer <clean|broken|empty> [vendored] -> a consumer checkout.
_consumer() { t_consumer_fixture "${_work}" _plant "$@"; }
# The advisory buildx pass needs a daemon and grades nothing; off for every case.
_at_root() { LINT_DOCKERFILES_BUILD_CHECK=0 bash "${LINTER}" --root "$1" 2>&1; }
_rc_at_root() {
  LINT_DOCKERFILES_BUILD_CHECK=0 t_rc bash "${LINTER}" --root "$1"
}

t_case "--root decides WHICH tree is graded, and the verdicts follow the argument"
_c_clean="$(_consumer clean)"
_c_broken="$(_consumer broken)"
t_assert_eq "0" "$(_rc_at_root "${_c_clean}")" \
  "the gate must be able to be green over a consumer, or the red below proves only that it is broken"
t_assert_eq "1" "$(_rc_at_root "${_c_broken}")" \
  "a gate that ignored --root would grade this repo's 24 Dockerfiles -- which are clean -- and report OK"
t_assert_contains "$(_at_root "${_c_broken}")" 'set in the SAME instruction'

t_case "the banner names the tree that was graded, and how much of it"
_out="$(_at_root "${_c_clean}")"
t_assert_contains "${_out}" "dockerfile lint under ${_c_clean}"
t_assert_contains "${_out}" "ENV instruction ordering on 2 Dockerfile(s)" \
  "a count that included this repo's own Dockerfiles would be a verdict about the wrong tree"

t_case "a vendored checkout inside the consumer is a gitlink, and is not graded"
_c_vendored="$(_consumer clean vendored)"
t_assert_eq "0" "$(_rc_at_root "${_c_vendored}")" \
  "grading the vendored hub AS the consumer is the same wrong-tree bug from the other direction"
t_assert_eq "1" "$(t_rc "${PY}" "${GATE}" "${_c_vendored}/${T_VENDORED}/Dockerfile")" \
  "and the vendored Dockerfile really is broken, so the green above is about scope, not a clean file"

t_case "a consumer with no Dockerfile is an ERROR, never a green verdict about nothing"
_c_empty="$(_consumer empty)"
t_assert_eq "1" "$(_rc_at_root "${_c_empty}")"
t_assert_contains "$(_at_root "${_c_empty}")" "No Dockerfiles found to lint under ${_c_empty}"

t_case "a consumer that ships .hadolint.yaml is graded by ITS waivers, not this repo's"
# DL3006 (untagged FROM) is ignored HERE and by nothing in the consumer's own
# config, so the verdict flipping to red is proof of which file was read.
_c_cfg="$(mktemp -d "${_work}/cfg.XXXXXX")"
git -C "${_c_cfg}" init -q
printf 'FROM debian\nENV A=1\n' > "${_c_cfg}/Dockerfile"
t_git_commit "${_c_cfg}"
t_assert_eq "0" "$(_rc_at_root "${_c_cfg}")" \
  "this repo's policy ignores DL3006, so without a consumer config the tree is green"
printf 'failure-threshold: warning\nignored: []\n' > "${_c_cfg}/.hadolint.yaml"
t_git_commit "${_c_cfg}"
t_assert_eq "1" "$(_rc_at_root "${_c_cfg}")"
t_assert_contains "$(_at_root "${_c_cfg}")" "DL3006"

t_case "a root that is not a git checkout refuses instead of guessing a scope"
_c_nogit="$(mktemp -d "${_work}/nogit.XXXXXX")"
printf 'FROM scratch\nENV A=1\n' > "${_c_nogit}/Dockerfile"
t_assert_eq "1" "$(_rc_at_root "${_c_nogit}")"
t_assert_contains "$(_at_root "${_c_nogit}")" "is not a git checkout" \
  "a scope guessed out of a non-checkout is a scope nobody chose"

t_case "a root that does not exist refuses, it does not fall back to this repo"
t_assert_eq "1" "$(_rc_at_root "${_work}/no-such-checkout")" \
  "falling back would grade a clean tree and report OK for a checkout nobody looked at"

t_case "--root with no value is a usage error, not a silent default"
t_assert_eq "1" "$(LINT_DOCKERFILES_BUILD_CHECK=0 t_rc bash "${LINTER}" --root)"

t_summary
