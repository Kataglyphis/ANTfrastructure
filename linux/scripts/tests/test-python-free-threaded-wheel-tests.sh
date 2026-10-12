#!/usr/bin/env bash
# test-free-threaded-wheel.sh: a project's tests on its installed free-threaded wheel; see docs/python-ci.md#the-suite-on-the-installed-wheel
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SCRIPTS="$(cd "${TESTS_DIR}/.." && pwd)"

t_skip_unless "a POSIX python3 (the helper reads the fixture's pyproject.toml)" t_posix_python

_work="$(mktemp -d)"; trap 'rm -rf "${_work}"' EXIT
WS="${_work}/ws"; TREE="${_work}/tree"; CALLS="${_work}/calls"; OUT="${_work}/out"; BIN="${_work}/bin"
mkdir -p "${TREE}/01-core" "${TREE}/02-toolchain/python" "${WS}/tests/unit" "${WS}/fixture_app" "${BIN}"
cp "${SCRIPTS}/01-core/python_uv.sh" "${SCRIPTS}/01-core/logging.sh" "${SCRIPTS}/01-core/versions.env" "${TREE}/01-core/"
cp "${SCRIPTS}/02-toolchain/python/test-free-threaded-wheel.sh" "${SCRIPTS}/02-toolchain/python/free-threaded-wheel.py" \
  "${TREE}/02-toolchain/python/"
cat > "${TREE}/02-toolchain/python/ci-common.sh" <<'CI_COMMON'
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../01-core" && pwd)/python_uv.sh"
detect_workspace() { export WORKSPACE_ROOT="${FIXTURE_WS}"; }
prepare_ci_workspace() { cd "${FIXTURE_WS}" || :; }
CI_COMMON
: > "${WS}/tests/unit/test_threads.py"
: > "${WS}/fixture_app/__init__.py"

# A uv that logs each call and seeds each venv with a python that records how pytest was started.
cat > "${BIN}/uv" <<'UV'
#!/usr/bin/env bash
printf 'uv %s\n' "$*" >> "${CALLS}"
case "$1 $2" in
  "python find") [ -z "${FAKE_NO_FT:-}" ] || exit 2; printf '%s\n' "${FAKE_BIN}/python-free-threaded" ;;
  "export --locked") while [ $# -gt 0 ]; do [ "$1" != -o ] || : > "$2"; shift; done ;;
  "venv --python")
    dir="${!#}"
    mkdir -p "${dir}/bin"
    cat > "${dir}/bin/python" <<'FAKE_INTERPRETER'
#!/usr/bin/env bash
[ "$1" != -VV ] || { echo "Python X.Y.Z free-threading build"; exit 0; }
printf 'pytest %s | cwd %s | FIXTURE_COMPILED=%s | staged %s\n' "$*" "${PWD}" "$(printenv FIXTURE_COMPILED)" \
  "$(cd "${PWD}" && find . -type f | sort | tr '\n' ' ')" >> "${CALLS}"
exit "${FAKE_PYTEST_RC:-0}"
FAKE_INTERPRETER
    chmod +x "${dir}/bin/python"
    ;;
esac
exit 0
UV
chmod +x "${BIN}/uv"

# The pin's own tags: the step defaults to versions.env's X.Y, so the fixture follows a Python upgrade.
MM="$(sed -n 's/^PYTHON_VERSION=\([0-9]*\.[0-9]*\)\..*/\1/p' "${SCRIPTS}/01-core/versions.env")"
CP="cp${MM//./}"
WHEEL="fixture_app-1.0-${CP}-${CP}t-manylinux_2_17_$(uname -m).whl"
DECLARED='"Programming Language :: Python :: Free Threading :: 2 - Beta"'
_pyproject() { printf '[project]\nname = "fixture_app"\nclassifiers = [%s]\n' "$1" > "${WS}/pyproject.toml"; }
# _dist <wheel>...: what ci_packaging.sh left in dist/.
_dist() { rm -rf "${WS}/dist"; mkdir -p "${WS}/dist"; local w; for w in "$@"; do : > "${WS}/dist/${w}"; done; }
# _run <args>: the script on a bare PATH.
_run() {
  : > "${CALLS}"
  env CALLS="${CALLS}" FIXTURE_WS="${WS}" FAKE_BIN="${BIN}" TMPDIR="${_work}" PATH="${BIN}:/usr/bin:/bin" \
    bash "${TREE}/02-toolchain/python/test-free-threaded-wheel.sh" "$@" > "${OUT}" 2>&1
}
ARGS=(--extra test --copy tests/unit/test_threads.py --env FIXTURE_COMPILED=1 --isolated -- -W error tests/unit/test_threads.py)

t_case "a declared project's tests run on the installed free-threaded wheel, outside the checkout"
_pyproject "${DECLARED}"
_dist "fixture_app-1.0-py3-none-any.whl" "fixture_app-1.0-${CP}-${CP}-manylinux_2_17_$(uname -m).whl" "${WHEEL}"
t_assert_ok _run "${ARGS[@]}"
t_assert_contains "$(cat "${CALLS}")" "uv python find ${MM}t" "the image's interpreter, found"
t_assert_contains "$(cat "${CALLS}")" "uv export --locked --no-emit-project --extra test --format requirements.txt" "the lock's set with the test extra, without the project"
t_assert_contains "$(cat "${CALLS}")" "uv pip install --python ${_work}/tmp." "into a fresh venv"
t_assert_contains "$(cat "${CALLS}")" "--no-deps dist/${WHEEL}" "the shipped wheel, without re-resolving its dependencies"
t_assert_contains "$(cat "${CALLS}")" "pytest -I -m pytest -p no:cacheprovider -W error tests/unit/test_threads.py" "isolated, with the caller's pytest arguments"
t_assert_contains "$(cat "${CALLS}")" "FIXTURE_COMPILED=1 | staged ./tests/unit/test_threads.py " "the env reaches pytest, and only the copied file is staged"
t_assert_eq "0" "$(grep -c "cwd ${WS}" "${CALLS}")" "never run from the checkout, where the sources would shadow the wheel"
t_assert_contains "$(cat "${OUT}")" "free-threaded wheel tests passed: ${WHEEL}"
t_assert_eq "" "$(find "${_work}" -mindepth 1 -maxdepth 1 -name 'tmp.*')" "the venv and the run directory are removed"

t_case "without --isolated pytest runs as python -m, so the run directory is importable"
t_assert_ok _run --copy tests --copy pyproject.toml -- -v
t_assert_contains "$(cat "${CALLS}")" "pytest -m pytest -p no:cacheprovider -v | "
t_assert_contains "$(cat "${CALLS}")" "staged ./pyproject.toml ./tests/unit/test_threads.py " "a directory is copied whole, at its relative path"

t_case "failing tests fail the run and name the wheel"
FAKE_PYTEST_RC=1 t_assert_fails _run "${ARGS[@]}"
t_assert_contains "$(cat "${OUT}")" "the tests failed against ${WHEEL}"

t_case "the cases in which ci_packaging.sh builds no free-threaded wheel skip, and say why"
PACKAGING_CROSS_TARGET=riscv64 t_assert_ok _run "${ARGS[@]}"
t_assert_contains "$(cat "${OUT}")" "free-threaded wheel tests skipped: the riscv64 cross build ships no ${CP}t wheel"
PYTHON_FREE_THREADED_WHEEL=off t_assert_ok _run "${ARGS[@]}"
t_assert_contains "$(cat "${OUT}")" "free-threaded wheel tests skipped: PYTHON_FREE_THREADED_WHEEL=off"
_pyproject '"Programming Language :: Python :: 3.14"'
t_assert_ok _run "${ARGS[@]}"
t_assert_contains "$(cat "${OUT}")" "free-threaded wheel tests skipped: no 'Programming Language :: Python :: Free Threading' classifier"
t_assert_eq "0" "$(grep -c '^uv ' "${CALLS}")" "a skip touches no uv"

t_case "PYTHON_FREE_THREADED_WHEEL=on tests an undeclared project's wheel, as the driver built one"
PYTHON_FREE_THREADED_WHEEL=on t_assert_ok _run "${ARGS[@]}"
t_assert_contains "$(cat "${OUT}")" "free-threaded wheel tests passed"

t_case "a declared project with no free-threaded wheel of this arch fails, and lists what dist/ holds"
_pyproject "${DECLARED}"
_dist "fixture_app-1.0-py3-none-any.whl" "fixture_app-1.0-${CP}-${CP}-manylinux_2_17_$(uname -m).whl"
t_assert_fails _run "${ARGS[@]}"
t_assert_contains "$(cat "${OUT}")" "expected one ${CP}t $(uname -m) wheel in dist/, found 0 among: fixture_app-1.0-${CP}-${CP}-manylinux"

t_case "no free-threaded interpreter fails, and none is downloaded"
_dist "${WHEEL}"
FAKE_NO_FT=1 t_assert_fails _run "${ARGS[@]}"
t_assert_contains "$(cat "${OUT}")" "no ${MM}t interpreter for the wheel tests"
t_assert_eq "0" "$(grep -c 'python install' "${CALLS}")"

t_case "a call without --copy, with a bad --env or with a missing path fails before any test"
t_assert_fails _run --extra test
t_assert_contains "$(cat "${OUT}")" "no --copy: name the tests to run against the installed wheel"
t_assert_fails _run --copy tests --env 1BAD
t_assert_contains "$(cat "${OUT}")" "--env needs NAME=VALUE, not '1BAD'"
t_assert_fails _run --copy tests/absent.py
t_assert_contains "$(cat "${OUT}")" "--copy tests/absent.py: no such file or directory"
t_assert_eq "0" "$(grep -c '^pytest' "${CALLS}")"

t_summary
