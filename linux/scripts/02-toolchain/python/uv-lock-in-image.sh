#!/usr/bin/env bash
# uv-lock-in-image.sh [--no-build-isolation-package NAME]... [--] [UV_LOCK_ARGS]: a consumer's uv lock in the family image, built against its torch (CON272).
set -euo pipefail

venv="${UV_LOCK_IMAGE_VENV:-/opt/venv}"
isolation=()
while [ "${1:-}" = --no-build-isolation-package ]; do
  isolation+=(--no-build-isolation-package "${2:?uv-lock-in-image.sh: --no-build-isolation-package needs a name}")
  shift 2
done
[ "${1:-}" != -- ] || shift

refuse() {
  echo "uv-lock-in-image.sh: $*" >&2
  exit 2
}
[ -x "${venv}/bin/python" ] || refuse "no ${venv}/bin/python; run it in the family Linux image"
[ -f pyproject.toml ] || refuse "no pyproject.toml in $(pwd)"
# A source built without isolation imports setuptools and wheel from the image's venv, which ships neither yet.
if ! "${venv}/bin/python" -c 'import setuptools, wheel' 2>/dev/null; then
  [ -w "${venv}" ] || refuse "${venv} lacks setuptools or wheel and is not writable; run the container as root"
  # The bound the lock of 2026-11-14 ran with.
  uv pip install --python "${venv}/bin/python" "setuptools<82" wheel >&2
fi
UV_PROJECT_ENVIRONMENT="${venv}" VIRTUAL_ENV="${venv}" exec uv lock "${isolation[@]}" "$@"
