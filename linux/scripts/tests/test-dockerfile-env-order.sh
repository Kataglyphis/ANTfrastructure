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

t_summary
