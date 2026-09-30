#!/usr/bin/env bash
# Gating static analysis. docs/python-ci.md#the-static-analysis-knobs-and-the-bandit-trap-between-them

# -e aborts on setup failures; gate failures are recorded by run_gate and raised once by assert_gates.
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

STATIC_ANALYSIS_EXTRA_PATHS="${STATIC_ANALYSIS_EXTRA_PATHS:-}"
# shellcheck disable=SC2206  # a space-separated path LIST, split deliberately
EXTRA_PATHS=( ${STATIC_ANALYSIS_EXTRA_PATHS} )
if [ "${#EXTRA_PATHS[@]}" -gt 0 ]; then
  info "Extra analysis paths: ${EXTRA_PATHS[*]}"
fi
# Setting BANDIT_EXCLUDES replaces this default list rather than extending it.
BANDIT_EXCLUDES="${BANDIT_EXCLUDES:-tests,.venv,.venv_static_analysis,ExternalLib,third_party,archive,docs/test_results}"

VENV_DIR="$WORKSPACE_ROOT/.venv_static_analysis"

UV_VENV_CLEAR=1 uv_venv_ensure "$VENV_DIR" "$PYTHON_VERSION" "virtual environment" VENV_WAS_PRESENT

uv_sync_project --no-wxpython

# Every analyser runs, so one push names every finding, and assert_gates gives one verdict.
gate_reset "static analysis (${PACKAGE_NAME})"

run_gate "codespell" uv_run codespell "$PACKAGE_NAME" tests docs/source/conf.py setup.py README.md ${EXTRA_PATHS[@]+"${EXTRA_PATHS[@]}"}
run_gate "bandit" uv_run bandit -r "$PACKAGE_NAME" ${EXTRA_PATHS[@]+"${EXTRA_PATHS[@]}"} -x "$BANDIT_EXCLUDES"
run_gate "vulture" uv_run vulture "$PACKAGE_NAME" tests docs/source/conf.py setup.py ${EXTRA_PATHS[@]+"${EXTRA_PATHS[@]}"}
# --no-fix: a gate judges the tree as committed, not a copy it just repaired.
run_gate "ruff check" uv_run ruff check --no-fix "$PACKAGE_NAME" tests docs/source/conf.py setup.py ${EXTRA_PATHS[@]+"${EXTRA_PATHS[@]}"}
# --check --diff, not a bare `format`: report, do not rewrite. Same argument.
run_gate "ruff format" uv_run ruff format --check --diff "$PACKAGE_NAME" tests docs/source/conf.py setup.py ${EXTRA_PATHS[@]+"${EXTRA_PATHS[@]}"}
run_gate "ty" uv_run ty check

if [ "$VENV_WAS_PRESENT" -eq 0 ]; then
  uv_venv_remove "$VENV_DIR"
fi

if [ -n "$ARCH" ]; then
  info "Static analysis completed for arch: $ARCH"
fi

# The verdict, once, and after the teardown above so a failing gate still cleans up.
assert_gates