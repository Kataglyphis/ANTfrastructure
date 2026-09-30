#!/usr/bin/env bash
# Builds the docs locally and in CI; python_uv.sh's --python pin makes it work as uid 1001 in :latest.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

VENV_DIR="${REPO_ROOT}/.venv"
REQUIREMENTS="${REPO_ROOT}/requirements.txt"

# Without the DocumANTation submodule, make html would fail deep inside sphinx.
THEME="${REPO_ROOT}/third_party/DocumANTation/sphinx-kataglyphis-theme"
if [ ! -d "${THEME}" ]; then
  echo "ERROR: ${THEME} is missing — check out the DocumANTation submodule first" >&2
  exit 1
fi

# shellcheck source=01-core/python_uv.sh
source "${REPO_ROOT}/linux/scripts/01-core/python_uv.sh"

uv_venv_create "${VENV_DIR}" ""
uv_pip_install_requirements "${VENV_DIR}" "${REQUIREMENTS}"
uv_venv_activate "${VENV_DIR}"

cd "${REPO_ROOT}/docs"
make html

# Without an index, the FTP deploy would sync an empty directory over the live site.
if [ ! -f "${REPO_ROOT}/docs/_build/html/index.html" ]; then
  echo "ERROR: make html reported success but docs/_build/html/index.html is absent" >&2
  exit 1
fi
echo "DOCS BUILD OK: ${REPO_ROOT}/docs/_build/html"
