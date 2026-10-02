#!/usr/bin/env bash
# Builds the sdist and wheels, auditwheel-repairing platform wheels, then any packaging/app.json app; PYTHON_VERSION (arg 1) defaults to 3.14.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/ci-common.sh" || { echo "Error: failed to source ci-common.sh" >&2; exit 1; }

detect_workspace

PYTHON_VERSION="${1:-${PYTHON_VERSION:-3.14}}"
info "Using Python version: $PYTHON_VERSION"

prepare_ci_workspace --cd

if command -v patchelf >/dev/null 2>&1; then
  info "patchelf already installed"
else
  SUDO_CMD=""
  if command -v sudo >/dev/null 2>&1; then
    SUDO_CMD="sudo"
  fi
  $SUDO_CMD apt-get update
  $SUDO_CMD apt-get install -y patchelf
fi

VENV_SOURCES="$WORKSPACE_ROOT/.venv_packaging_sources"
uv_venv_ensure "$VENV_SOURCES" "$PYTHON_VERSION" "source packaging venv"

uv_sync_project --no-wxpython

uv build

export CYTHONIZE="True"

VENV_BINARIES="$WORKSPACE_ROOT/.venv_packaging_binaries"
uv_venv_ensure "$VENV_BINARIES" "$PYTHON_VERSION" "binary packaging venv"

uv_sync_project --no-wxpython

uv build

mkdir -p dist repaired
shopt -s nullglob
info "Found wheels:"
ls -la dist || true

for whl in dist/*.whl; do
  info "Inspecting wheel: $whl"
  if auditwheel show "$whl" >/dev/null 2>&1; then
    info "  Platform wheel detected -> repairing: $whl"
    auditwheel repair "$whl" -w repaired/ || { err "auditwheel failed on $whl"; exit 1; }
  else
    info "  Pure/Python wheel detected -> copying unchanged: $whl"
    cp "$whl" repaired/
  fi
done

rm -f dist/*.whl || true
mv repaired/*.whl dist/ || true
rmdir repaired || true

info "Final wheels in dist/:"
ls -la dist || true

# packaging/app.json opts the consumer in; its packages need the AppImage tooling amd64/arm64 ships, so riscv64 ships wheels only (docs/python-app-bundles.md § Packages).
if [ -f packaging/app.json ]; then
  if [ "$(uname -m)" = "riscv64" ]; then
    warn "packaging/app.json present: the tar/deb/AppImage packages are amd64/arm64, so riscv64 ships wheels only"
  else
    bash "$SCRIPT_DIR/../../06-packaging/python-app-bundle.sh" --wheel-dir dist --out-dir build/app-bundle
    bash "$SCRIPT_DIR/../../06-packaging/python-app-package.sh" --bundle build/app-bundle --out-dir dist/packages
  fi
fi