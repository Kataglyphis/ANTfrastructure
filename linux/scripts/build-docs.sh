#!/usr/bin/env bash
# Builds the hub's Sphinx site; in the image from its own Sphinx stack, offline. See docs/project-info.md#building-the-hubs-docs
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

VENV_DIR="${REPO_ROOT}/docs/.venv"
IMAGE_VENV=/opt/venv

# Without the DocumANTation submodule, make html would fail deep inside sphinx.
THEME="${REPO_ROOT}/third_party/DocumANTation/sphinx-kataglyphis-theme"
if [ ! -d "${THEME}" ]; then
  echo "ERROR: ${THEME} is missing — check out the DocumANTation submodule first" >&2
  exit 1
fi

# shellcheck source=01-core/python_uv.sh
source "${REPO_ROOT}/linux/scripts/01-core/python_uv.sh"

# image_docs_venv <python>: a venv that sees <python>'s site-packages through a .pth, with the vendored theme in it.
image_docs_venv() {
  local python="$1" site venv_site
  site="$("${python}" -c 'import sysconfig; print(sysconfig.get_path("purelib"))')"
  rm -rf "${VENV_DIR}"
  uv venv --offline --quiet --python "${python}" "${VENV_DIR}"
  venv_site="$("${VENV_DIR}/bin/python" -c 'import sysconfig; print(sysconfig.get_path("purelib"))')"
  printf '%s\n' "${site}" > "${venv_site}/image-site-packages.pth"
  # No build isolation: setuptools comes from the image too, so nothing is downloaded.
  uv pip install --offline --quiet --python "${VENV_DIR}/bin/python" --no-deps --no-build-isolation -e "${THEME}"
}

# theme_requirements_met: every requirement the theme declares is installed at a version it accepts; names the rest.
theme_requirements_met() {
  "${VENV_DIR}/bin/python" - <<'PY'
import sys
from importlib.metadata import PackageNotFoundError, requires, version

try:
    from packaging.requirements import Requirement
except ImportError:
    from pip._vendor.packaging.requirements import Requirement

unmet = []
for spec in requires("sphinx-kataglyphis-theme") or []:
    req = Requirement(spec)
    if req.marker is not None and not req.marker.evaluate({"extra": ""}):
        continue
    try:
        have = version(req.name)
    except PackageNotFoundError:
        unmet.append(f"{req} (absent)")
        continue
    if not req.specifier.contains(have, prereleases=True):
        unmet.append(f"{req} (the image has {have})")
if unmet:
    print("the image lacks what sphinx-kataglyphis-theme needs: " + ", ".join(unmet), file=sys.stderr)
    sys.exit(1)
PY
}

check_docs_lock() {
  uv lock --project "${REPO_ROOT}/docs" --check --offline || err "docs/uv.lock is missing or stale; run uv lock --project docs"
}

# docs_venv: CI uses the image offline; a workstation syncs the docs project's lock.
docs_venv() {
  if [ -d "${IMAGE_VENV}" ]; then
    check_docs_lock
    image_docs_venv "$(command -v python3)"
    theme_requirements_met || err "CI and the image never download the docs stack; put it in the image"
    info "Docs from the image's Sphinx stack and the vendored theme, offline"
  elif [ "${CI:-}" = true ]; then
    err "no ${IMAGE_VENV}: the docs build in the family image (build-docs.yml), never from PyPI in CI"
  else
    check_docs_lock
    UV_PROJECT_ENVIRONMENT="${VENV_DIR}" uv sync --project "${REPO_ROOT}/docs" --locked
  fi
}

docs_venv
uv_venv_activate "${VENV_DIR}"

cd "${REPO_ROOT}/docs"
# The venv's own interpreter: the image's sphinx-build would run without the theme.
make html SPHINXBUILD="${VENV_DIR}/bin/python -m sphinx"

# Without an index, the FTP deploy would sync an empty directory over the live site.
if [ ! -f "${REPO_ROOT}/docs/_build/html/index.html" ]; then
  echo "ERROR: make html reported success but docs/_build/html/index.html is absent" >&2
  exit 1
fi
echo "DOCS BUILD OK: ${REPO_ROOT}/docs/_build/html"
