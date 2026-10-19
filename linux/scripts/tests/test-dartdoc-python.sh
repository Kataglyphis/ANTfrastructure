#!/usr/bin/env bash
# dartdoc_build_prepare_python_env takes the image's python3 and never downloads in CI or the image. See docs/shared-script-libraries.md#the-renderers-python
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
LIB="$(cd "${TESTS_DIR}/../lib" && pwd)"
REAL_PY="$(command -v "${PREFLIGHT_PYTHON:-python3}")"
PIN="$(sed -n 's/^markdown-it-py==//p' "${LIB}/dartdoc-guides.requirements.txt")"
_WORK="$(mktemp -d)"
trap 'rm -rf "${_WORK}"' EXIT

# _prepare <parser version|absent> <image dir> [VAR=value...]: prints the chosen interpreter, "venv" when the host venv ran, and the exit code.
_prepare() {
  local parser="$1" image="$2" dir
  shift 2
  dir="$(mktemp -d "${_WORK}/py.XXXXXX")"
  mkdir -p "${dir}/stub/markdown_it" "${dir}/bin"
  if [ "${parser}" = absent ]; then
    printf 'raise ImportError("no parser")\n' > "${dir}/stub/markdown_it/__init__.py"
  else
    printf '__version__ = "%s"\n' "${parser}" > "${dir}/stub/markdown_it/__init__.py"
  fi
  # A stub package ahead of site-packages: the image's own python3 carries the real parser.
  printf '#!/usr/bin/env bash\nPYTHONPATH="%s" exec "%s" "$@"\n' "${dir}/stub" "${REAL_PY}" > "${dir}/bin/python3"
  chmod +x "${dir}/bin/python3"
  # Into a file, not a pipe: err() must exit this shell, and the variable must survive.
  env -u CI -u DARTDOC_BUILD_PYTHON PATH="${dir}/bin:${PATH}" "$@" bash -c '
    source "$1/dartdoc-build.sh"
    _DARTDOC_BUILD_IMAGE_VENV="$2"
    _dartdoc_build_host_venv() { echo venv; DARTDOC_BUILD_PYTHON=/venv/bin/python; }
    dartdoc_build_prepare_python_env > "$3" 2>&1
    grep -x venv "$3"
    echo "python=${DARTDOC_BUILD_PYTHON:-}"' _ "${LIB}" "${image}" "${dir}/log" 2>/dev/null
  echo "rc=$?"
}
NO_IMAGE="${_WORK}/no-image"
IMAGE="${_WORK}"

t_case "the pin is read from the one requirements file"
t_assert_eq 1 "$(printf '%s\n' "${PIN}" | grep -cE '^[0-9]+\.[0-9]+')" "dartdoc-guides.requirements.txt must pin markdown-it-py==X.Y"

t_case "a python3 that imports the pinned parser is used, inside or outside the image"
out="$(_prepare "${PIN}" "${IMAGE}" CI=true)"
t_assert_contains "${out}" "python=${_WORK}/py." "the image's python3 carries the parser"
t_assert_contains "${out}" "rc=0"
t_assert_eq 0 "$(printf '%s\n' "${out}" | grep -cx venv)" "nothing is downloaded when python3 has it"
t_assert_contains "$(_prepare "${PIN}" "${NO_IMAGE}")" "python=${_WORK}/py."

t_case "CI never downloads the parser: it fails and names the gap"
out="$(_prepare absent "${NO_IMAGE}" CI=true)"
t_assert_contains "${out}" "rc=1"
t_assert_eq 0 "$(printf '%s\n' "${out}" | grep -cx venv)"
t_assert_contains "$(_prepare 0.0.1 "${NO_IMAGE}" CI=true)" "rc=1" "another version is not the pinned one"

t_case "inside the image (its /opt/venv) a missing parser fails too, CI or not"
out="$(_prepare absent "${IMAGE}")"
t_assert_contains "${out}" "rc=1"
t_assert_eq 0 "$(printf '%s\n' "${out}" | grep -cx venv)"

t_case "a workstation without the image builds the venv"
out="$(_prepare absent "${NO_IMAGE}")"
t_assert_contains "${out}" "rc=0"
t_assert_eq 1 "$(printf '%s\n' "${out}" | grep -cx venv)"
t_assert_contains "${out}" "python=/venv/bin/python"

t_case "the caller's interpreter wins over every probe"
out="$(_prepare absent "${IMAGE}" CI=true DARTDOC_BUILD_PYTHON=/given/python)"
t_assert_contains "${out}" "python=/given/python"
t_assert_contains "${out}" "rc=0"

t_case "a requirements file without the pin fails before any probe"
printf 'something-else==1.0\n' > "${_WORK}/req.txt"
t_assert_contains "$(_prepare "${PIN}" "${NO_IMAGE}" DARTDOC_BUILD_REQUIREMENTS="${_WORK}/req.txt")" "rc=1"

t_summary
