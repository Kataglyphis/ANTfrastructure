#!/usr/bin/env bash
# The python-ci drivers' default interpreters: ci_tests.sh's legs and ci_build_docs.sh's coverage version are the
# image's CPython (versions.env PYTHON_VERSION). docs/python-ci.md#trap-3--onnx-runtime-comes-from-the-chain-not-pypi
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SCRIPTS="$(cd "${TESTS_DIR}/.." && pwd)"
IMAGE_PY="$(sed -n 's/^PYTHON_VERSION=\([0-9][0-9]*\.[0-9][0-9]*\)\..*/\1/p' "${SCRIPTS}/01-core/versions.env")"

_work="$(mktemp -d)"; trap 'rm -rf "${_work}"' EXIT
WS="${_work}/ws"; REC="${_work}/calls"; TREE="${_work}/tree"
mkdir -p "${WS}/docs" "${_work}/bin" "${TREE}/01-core" "${TREE}/02-toolchain/python"
cp "${SCRIPTS}/01-core/python_uv.sh" "${SCRIPTS}/01-core/logging.sh" "${TREE}/01-core/"
cp "${SCRIPTS}/02-toolchain/python/ci_tests.sh" "${SCRIPTS}/02-toolchain/python/ci_build_docs.sh" "${TREE}/02-toolchain/python/"
printf '#!/usr/bin/env bash\nprintf "make %%s\\n" "$*" >> "${REC}"\n' > "${_work}/bin/make"; chmod +x "${_work}/bin/make"
# The real python_uv.sh (is_experimental_python and its knob), with every uv and workspace effect recorded instead.
cat > "${TREE}/02-toolchain/python/ci-common.sh" <<'CI_COMMON'
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../01-core" && pwd)/python_uv.sh"
detect_workspace() { export WORKSPACE_ROOT="${FIXTURE_WS}"; }
prepare_ci_workspace() { :; }
derive_package_name() { printf 'pkg'; }
uv_venv_create() { echo "interpreter $2" >> "${REC}"; }
uv_venv_ensure() { echo "interpreter $2" >> "${REC}"; printf -v "$4" 1; }
uv_run() { echo "run $*" >> "${REC}"; }
uv_venv_activate() { :; }; uv_venv_deactivate() { :; }; uv_venv_remove() { :; }; uv_sync_project() { :; }
CI_COMMON

# _driver <ci_tests|ci_build_docs> [positionals...]: a caller that sets no version knob, as the reusable lane.
_driver() {
  : > "${REC}"
  env -u PY_VERSIONS -u COVERAGE_VERSION -u EXPERIMENTAL_PYTHON_VERSIONS PATH="${_work}/bin:${PATH}" \
    REC="${REC}" FIXTURE_WS="${WS}" GIT_CONFIG_GLOBAL="${_work}/gitconfig" CI_TESTS_LOG_FILE="${_work}/tests.log" \
    bash "${TREE}/02-toolchain/python/$1.sh" "${@:2}" >/dev/null 2>&1
}
_legs() { sed -n 's/^interpreter //p' "${REC}" | tr '\n' ' ' | sed 's/ $//'; }

t_case "versions.env names the image interpreter this suite holds the defaults to"
t_assert_ok test -n "${IMAGE_PY}"

t_case "ci_tests.sh with no version runs one leg, on the image interpreter the chain ORT wheels are built for"
t_assert_ok _driver ci_tests
t_assert_eq "${IMAGE_PY}" "$(_legs)" "no other stable leg: a cp313 venv cannot take a cp314 chain wheel"

t_case "the empty positional the reusable lane passes falls through to the same default"
t_assert_ok _driver ci_tests pkg ''
t_assert_eq "${IMAGE_PY}" "$(_legs)"

t_case "a consumer's own list still wins"
t_assert_ok _driver ci_tests pkg "${IMAGE_PY} ${IMAGE_PY}t"
t_assert_eq "${IMAGE_PY} ${IMAGE_PY}t" "$(_legs)"

t_case "ci_build_docs.sh with no version publishes the coverage of the default leg, not another leg's beside it"
t_assert_ok _driver ci_tests
_html="$(sed -n 's/^run pytest .*--cov-report=html:\([^ ]*\) .*/\1/p' "${REC}")"
_xml="$(sed -n 's/^run pytest .*--cov-report=xml:\([^ ]*\) .*/\1/p' "${REC}")"
t_assert_eq "${WS}/docs/test_results/coverage-html-${IMAGE_PY}" "${_html}" "the default leg's HTML report"
mkdir -p "${_html}" "${WS}/docs/test_results/coverage-html-3.13"
echo "default leg" > "${_html}/index.html"; echo "default leg" > "${_xml}"
echo "other leg" > "${WS}/docs/test_results/coverage-html-3.13/index.html"; echo "other leg" > "${WS}/docs/test_results/coverage-3.13.xml"
t_assert_ok _driver ci_build_docs
t_assert_eq "${IMAGE_PY}" "$(_legs)" "the docs venv syncs on the image interpreter too"
t_assert_eq "default leg" "$(cat "${WS}/docs/source/_static/coverage/index.html" 2>&1)"
t_assert_eq "default leg" "$(cat "${WS}/docs/source/_static/coverage.xml" 2>&1)"
t_assert_contains "$(cat "${REC}")" "make html" "and the docs are built"

t_summary
