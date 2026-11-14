#!/usr/bin/env bash
# recipe-pytest.sh with every uv effect recorded: one venv per pinned Python, extras and lock, and pytest from the copy.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
# shellcheck source=linux/scripts/tests/python-ci-fixture.sh
source "${TESTS_DIR}/python-ci-fixture.sh"
SCRIPTS="$(cd "${TESTS_DIR}/.." && pwd)"
PINNED="$(sed -n 's/^PYTHON_VERSION=\([0-9][0-9]*\.[0-9][0-9]*\)\..*/\1/p' "${SCRIPTS}/01-core/versions.env")"

_work="$(mktemp -d)"; trap 'rm -rf "${_work}"' EXIT
python_ci_fixture "${_work}" "${SCRIPTS}" 01-core/versions.env 02-toolchain/python/recipe-pytest.sh || exit 1
REC="${CALLS}"
# A venv whose python records what pytest was asked; a sync that records its extras, or fails when told to.
cat >> "${TREE}/02-toolchain/python/ci-common.sh" <<'CI_COMMON'
uv_venv_create() {
  echo "create $1 python=$2" >> "${REC}"
  mkdir -p "$1/bin"
  printf '#!/usr/bin/env bash\necho "pytest from $(pwd): $*" >> "%s"\necho "path ${PATH%%%%:*} venv ${VIRTUAL_ENV}" >> "%s"\n' "${REC}" "${REC}" > "$1/bin/python"
  chmod +x "$1/bin/python"
}
uv_venv_activate() { :; }
uv_sync_project() { echo "sync extras=${UV_SYNC_EXTRAS}" >> "${REC}"; [ -z "${FAIL_SYNC:-}" ]; }
CI_COMMON

copy="${_work}/copy"
mkdir -p "${copy}"
printf '[project]\nname = "caller"\n' > "${copy}/pyproject.toml"
printf 'version = 1\n' > "${copy}/uv.lock"
venvs="${_work}/venvs"

_recipe() {
  (cd "${copy}" && PATH="${BIN}:${PATH}" REC="${REC}" RECIPE_PYTEST_VENV_ROOT="${venvs}" \
    bash "${TREE}/02-toolchain/python/recipe-pytest.sh" "$@") > "${OUT}" 2>&1
}
_count() { grep -c -e "$1" "${REC}" || true; }

t_case "the suite reads the pinned Python it holds the script to"
t_assert_ok test -n "${PINNED}"

: > "${REC}"
_recipe --extra test -- tests/unit/test_a.py -k fast
_recipe --extra test -- tests/unit/test_b.py
t_case "two recipes with the same extras build one venv on the pinned Python and sync it once"
t_assert_eq 1 "$(_count '^create ')" "one venv"
t_assert_grep "${REC}" "^create ${venvs}/recipe-pytest-py${PINNED}-test-[0-9a-f]{12} python=${PINNED}$"
t_assert_eq 1 "$(_count '^sync extras=test$')" "one sync, with the test extra"
t_case "the venv is active for pytest, so a test that starts python3 itself finds it first"
t_assert_grep "${REC}" "^path ${venvs}/recipe-pytest-py${PINNED}-test-[0-9a-f]{12}/bin venv ${venvs}/recipe-pytest-py${PINNED}-test-[0-9a-f]{12}$"
t_case "pytest runs from the recipe's copy with the recipe's own arguments"
t_assert_grep "${REC}" "^pytest from ${copy}: -m pytest -q -p no:cacheprovider tests/unit/test_a.py -k fast$"
t_assert_grep "${REC}" "^pytest from ${copy}: -m pytest -q -p no:cacheprovider tests/unit/test_b.py$"

: > "${REC}"
_recipe --extra test --extra app tests/unit/test_c.py
t_case "another set of extras gets a venv of its own, and the -- before pytest's arguments is optional"
t_assert_eq 1 "$(_count '^sync extras=test,app$')" "a sync with both extras"
t_assert_grep "${REC}" "^pytest from ${copy}: -m pytest -q -p no:cacheprovider tests/unit/test_c.py$"

: > "${REC}"
printf 'version = 2\n' > "${copy}/uv.lock"
_recipe --extra test -- tests/unit/test_a.py
t_case "a changed lock is synced into a new venv, never into the old one"
t_assert_eq 1 "$(_count '^create ')" "a new venv for the new lock"

: > "${REC}"
printf 'version = 3\n' > "${copy}/uv.lock"
t_case "a failed sync fails the recipe and leaves nothing that reads as synced"
export FAIL_SYNC=1
t_assert_fails _recipe --extra test -- tests/unit/test_a.py
unset FAIL_SYNC
t_assert_eq 0 "$(_count '^pytest from ')" "no pytest after a failed sync"
_recipe --extra test -- tests/unit/test_a.py
t_assert_eq 2 "$(_count '^sync extras=test$')" "the next recipe syncs again"

t_summary
