#!/usr/bin/env bash
# uv-lock-in-image.sh with a fake image venv and uv: setuptools and wheel only when missing, the lock against that venv, refusals.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SCRIPT="$(cd "${TESTS_DIR}/.." && pwd)/02-toolchain/python/uv-lock-in-image.sh"

_work="$(mktemp -d)"; trap 'chmod -R u+w "${_work}"; rm -rf "${_work}"' EXIT
mkdir -p "${_work}/bin" "${_work}/project" "${_work}/venv/bin"
printf '[project]\nname = "caller"\n' > "${_work}/project/pyproject.toml"
# uv records each call with the environment the lock reads; the venv's python answers the import probe as told.
printf '%s\n' '#!/usr/bin/env bash' 'echo "uv $* | env=${UV_PROJECT_ENVIRONMENT:-} venv=${VIRTUAL_ENV:-}" >> "${CALLS}"' > "${_work}/bin/uv"
printf '%s\n' '#!/usr/bin/env bash' '[ -n "${HAS_SETUPTOOLS:-}" ]' > "${_work}/venv/bin/python"
chmod +x "${_work}/bin/uv" "${_work}/venv/bin/python"
CALLS="${_work}/calls"

_lock() {
  : > "${CALLS}"
  (cd "${_work}/project" && PATH="${_work}/bin:${PATH}" CALLS="${CALLS}" UV_LOCK_IMAGE_VENV="${VENV:-${_work}/venv}" \
    bash "${SCRIPT}" "$@") > "${_work}/out" 2>&1
}

t_case "a venv without setuptools gets them first, and the lock runs against that venv"
_lock --no-build-isolation-package torchvision -- --upgrade-package tomli-w
t_assert_eq "0" "$?"
t_assert_eq "uv pip install --python ${_work}/venv/bin/python setuptools<82 wheel | env= venv=" "$(sed -n 1p "${CALLS}")"
t_assert_eq "uv lock --no-build-isolation-package torchvision --upgrade-package tomli-w | env=${_work}/venv venv=${_work}/venv" \
  "$(sed -n 2p "${CALLS}")"

t_case "a venv that has them is left alone"
HAS_SETUPTOOLS=1 _lock
t_assert_eq "uv lock | env=${_work}/venv venv=${_work}/venv" "$(cat "${CALLS}")"

t_case "no image venv, no project, or a read-only venv without setuptools refuse before uv runs"
VENV="${_work}/missing" _lock; _rc=$?
t_assert_eq "2" "${_rc}"
t_assert_contains "$(cat "${_work}/out")" "run it in the family Linux image"
mv "${_work}/project/pyproject.toml" "${_work}/pyproject.toml"
_lock; _rc=$?
t_assert_eq "2" "${_rc}"
t_assert_contains "$(cat "${_work}/out")" "no pyproject.toml"
mv "${_work}/pyproject.toml" "${_work}/project/pyproject.toml"
chmod a-w "${_work}/venv"
_lock; _rc=$?
chmod u+w "${_work}/venv"
t_assert_eq "2" "${_rc}"
t_assert_contains "$(cat "${_work}/out")" "is not writable"
t_assert_eq "" "$(cat "${CALLS}")"

t_summary
