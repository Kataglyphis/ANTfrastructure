#!/usr/bin/env bash
# ci_static_analysis.sh - Generic Python static analysis runner
#
# Usage:
#   ci_static_analysis.sh [arch] [python_version] [package_name]
#
# Environment variables:
#   ARCH - Architecture (optional, for CI matrix parity)
#   PYTHON_VERSION - Python version (default: 3.14)
#   PACKAGE_NAME - Package name (derived from pyproject.toml if not specified)
#   WORKSPACE_ROOT - Workspace root directory

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../01-core/python_uv.sh" || { echo "Error: failed to source python_uv.sh" >&2; exit 1; }

detect_workspace

ARCH="${1:-${ARCH:-}}"
PYTHON_VERSION="${2:-${PYTHON_VERSION:-3.14}}"
PACKAGE_NAME="${3:-${PACKAGE_NAME:-}}"

if [ -z "$PACKAGE_NAME" ] && [ -f "$WORKSPACE_ROOT/pyproject.toml" ]; then
  PACKAGE_NAME=$(grep -m1 'name[[:space:]]*=' "$WORKSPACE_ROOT/pyproject.toml" | sed 's/.*=[[:space:]]*"\([^"]*\)".*/\1/' || echo "")
fi
PACKAGE_NAME="${PACKAGE_NAME:-$(basename "$WORKSPACE_ROOT")}"

info "Using Python version: $PYTHON_VERSION"
info "Running static analysis for package: $PACKAGE_NAME"

git config --global --add safe.directory "$WORKSPACE_ROOT" || true

VENV_DIR="$WORKSPACE_ROOT/.venv_static_analysis"
VENV_WAS_PRESENT=0

if [ -d "$VENV_DIR" ]; then
  info "Using existing virtual environment at: $VENV_DIR"
  VENV_WAS_PRESENT=1
  uv_venv_activate "$VENV_DIR"
else
  info "Creating virtual environment with Python $PYTHON_VERSION at: $VENV_DIR"
  UV_VENV_CLEAR=1 uv_venv_create "$VENV_DIR" "$PYTHON_VERSION"
fi

uv_sync_project --no-wxpython

uv_run codespell "$PACKAGE_NAME" tests docs/source/conf.py setup.py README.md 2>/dev/null || true
uv_run --active bandit -r "$PACKAGE_NAME" \
  -x tests,.venv,.venv_static_analysis,ExternalLib,archive,docs/test_results 2>/dev/null || true
uv_run --active vulture "$PACKAGE_NAME" tests docs/source/conf.py setup.py 2>/dev/null || true
uv_run --active ruff check --fix "$PACKAGE_NAME" tests docs/source/conf.py setup.py || true
uv_run --active ruff format "$PACKAGE_NAME" tests docs/source/conf.py setup.py || true
uv_run --active ty check 2>/dev/null || true

if [ "$VENV_WAS_PRESENT" -eq 0 ]; then
  uv_venv_remove "$VENV_DIR"
fi

if [ -n "$ARCH" ]; then
  info "Static analysis completed for arch: $ARCH"
fi