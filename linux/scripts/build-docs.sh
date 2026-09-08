#!/usr/bin/env bash
# build-docs.sh — build docs/_build/html. One entry point, local and in CI.
# Was five inline lines in .github/workflows/build-docs.yml, and that copy also
# hand-rolled the venv, bypassing 01-core/python_uv.sh — whose --python pin is
# what makes the install work as uid 1001 inside :latest-cross (uv otherwise
# honours the image's root-owned UV_PYTHON over an activated .venv).
# Usage: bash linux/scripts/build-docs.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

VENV_DIR="${REPO_ROOT}/.venv"
REQUIREMENTS="${REPO_ROOT}/requirements.txt"

# The theme is installed editable from third_party/DocumANTation, so a checkout
# without that submodule would install nothing and `make html` would fail deep
# inside sphinx on a missing theme. Say so here instead.
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

# A green sphinx run that produced no index is the "gate that covers nothing"
# shape: the FTP deploy would then sync an empty directory over the live site.
if [ ! -f "${REPO_ROOT}/docs/_build/html/index.html" ]; then
  echo "ERROR: make html reported success but docs/_build/html/index.html is absent" >&2
  exit 1
fi
echo "DOCS BUILD OK: ${REPO_ROOT}/docs/_build/html"
