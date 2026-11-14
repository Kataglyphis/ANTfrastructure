#!/usr/bin/env bash
# recipe-pytest.sh [--extra NAME]... [--] PYTEST_ARGS: a mutation recipe's pytest on the pinned Python, one venv per lock.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/ci-common.sh" || { echo "Error: failed to source ci-common.sh" >&2; exit 1; }

extras=()
while [ "${1:-}" = --extra ]; do
  extras+=("${2:?recipe-pytest.sh: --extra needs a name}")
  shift 2
done
[ "${1:-}" != -- ] || shift

version="${DEFAULT_PYTHON_VERSION:?recipe-pytest.sh: no pinned Python (PYTHON_VERSION in the versions.env beside python_uv.sh)}"
extras_csv="$(IFS=,; printf '%s' "${extras[*]}")"
# Each recipe runs in a new copy of the caller, so the venv lives outside it, keyed by what a sync reads.
lock_key="$(cat pyproject.toml uv.lock 2>/dev/null | sha256sum | cut -c1-12)"
venv="${RECIPE_PYTEST_VENV_ROOT:-/tmp}/recipe-pytest-py${version}-${extras_csv:-none}-${lock_key}"
mkdir -p "$(dirname "${venv}")"
(
  # Parallel recipes share one venv; the lock keeps two of them from building it at once.
  flock 9
  if [ ! -f "${venv}/.synced" ]; then
    uv_venv_create "${venv}" "${version}" >&2
    uv_venv_activate "${venv}" >&2
    UV_SYNC_EXTRAS="${extras_csv}" uv_sync_project >&2
    touch "${venv}/.synced"
  fi
) 9>"${venv}.lock"

# Active as the test leg's venv is: a test that starts `python3` itself must find this venv, not the image's /opt/venv.
export VIRTUAL_ENV="${venv}" PATH="${venv}/bin:${PATH}"
# python -m from the copy's root, so the package imported is the recipe's mutated one, not the copy that synced.
exec "${venv}/bin/python" -m pytest -q -p no:cacheprovider "$@"
