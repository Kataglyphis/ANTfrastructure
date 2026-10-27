#!/usr/bin/env bash
# Real uv verifies dependency-only installation offline; package index and network behavior are outside this fixture.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
source "${TESTS_DIR}/../01-core/python_uv.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT
export UV_CACHE_DIR="${WORK}/cache" UV_PYTHON_DOWNLOADS=never
unset VIRTUAL_ENV UV_PYTHON ORT_CHAIN_WHEEL_DIR
mkdir -p "${WORK}/project"
cat > "${WORK}/project/pyproject.toml" <<'TOML'
[project]
name = "uv-sync-group-fixture"
version = "0.0.0"
requires-python = ">=3.10"
dependencies = []
[build-system]
requires = ["missing-build-backend-for-group-fixture==1.0"]
build-backend = "missing_build_backend"
[dependency-groups]
docs = []
TOML
cd "${WORK}/project" || exit 1
python="$(command -v python3)"
uv lock --offline --python "${python}" >/dev/null || exit 1
uv venv --offline --python "${python}" "${WORK}/venv" >/dev/null || exit 1
_CURRENT_VENV_PATH="${WORK}/venv"

t_case "the selected group sync succeeds without building the project"
t_assert_ok uv_sync_project --locked --only-group docs

t_case "the same project cannot be installed normally with its missing backend"
t_assert_fails env UV_OFFLINE=1 UV_PROJECT_ENVIRONMENT="${WORK}/venv" uv sync --locked --no-dev
t_summary
