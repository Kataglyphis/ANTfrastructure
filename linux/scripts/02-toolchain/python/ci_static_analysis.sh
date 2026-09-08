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

# -e stays: a failing venv bootstrap or `uv sync` below must still abort. It is
# compatible with the gate batch because run_gate runs its command in a `||`
# list, which -e does not treat as fatal - the failure is recorded and re-raised
# once, by assert_gates at the bottom.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/ci-common.sh" || { echo "Error: failed to source ci-common.sh" >&2; exit 1; }
# shellcheck source=../../01-core/gates.sh
source "$SCRIPT_DIR/../../01-core/gates.sh" || { echo "Error: failed to source gates.sh" >&2; exit 1; }

detect_workspace

ARCH="${1:-${ARCH:-}}"
PYTHON_VERSION="${2:-${PYTHON_VERSION:-3.14}}"
PACKAGE_NAME="$(derive_package_name "${3:-${PACKAGE_NAME:-}}")"

info "Using Python version: $PYTHON_VERSION"
info "Running static analysis for package: $PACKAGE_NAME"

git config --global --add safe.directory "$WORKSPACE_ROOT" || true

VENV_DIR="$WORKSPACE_ROOT/.venv_static_analysis"

UV_VENV_CLEAR=1 uv_venv_ensure "$VENV_DIR" "$PYTHON_VERSION" "virtual environment" VENV_WAS_PRESENT

uv_sync_project --no-wxpython

# GATING since 2026-09-08. Every tool used to run behind `|| true` with its
# diagnostics sent to /dev/null: six analysers whose findings reached no log
# and whose verdict reached no exit code. A gate that passes while covering
# nothing is a defect.
#
# run_gate/assert_gates (01-core/gates.sh) keep the one good property the
# `|| true` chain had by accident - all six run, so one push names every
# finding - and add the one it lacked: a verdict.
gate_reset "static analysis (${PACKAGE_NAME})"

run_gate "codespell" uv_run codespell "$PACKAGE_NAME" tests docs/source/conf.py setup.py README.md
run_gate "bandit" uv_run bandit -r "$PACKAGE_NAME" -x tests,.venv,.venv_static_analysis,ExternalLib,third_party,archive,docs/test_results
run_gate "vulture" uv_run vulture "$PACKAGE_NAME" tests docs/source/conf.py setup.py
# --no-fix, not --fix: a gate judges the tree as COMMITTED. `--fix` rewrote the
# working tree and then reported on the repaired copy, so this step could only
# ever be green and the finding surfaced in the next `git status` instead.
run_gate "ruff check" uv_run ruff check --no-fix "$PACKAGE_NAME" tests docs/source/conf.py setup.py
# --check --diff, not a bare `format`: report, do not rewrite. Same argument.
run_gate "ruff format" uv_run ruff format --check --diff "$PACKAGE_NAME" tests docs/source/conf.py setup.py
run_gate "ty" uv_run ty check

if [ "$VENV_WAS_PRESENT" -eq 0 ]; then
  uv_venv_remove "$VENV_DIR"
fi

if [ -n "$ARCH" ]; then
  info "Static analysis completed for arch: $ARCH"
fi

# The verdict, once, and after the teardown above so a failing gate still cleans up.
assert_gates